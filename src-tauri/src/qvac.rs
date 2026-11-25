//! QVAC TranscribePsy, running in its own process.
//!
//! Handy upstream (the project this was forked from) at the time of this integration:
//! `4807c21a7bb9a3bf2d52578a9b541e165b6bc8b9`
//!
//! transcribe-cpp and qvac-fabric-speech.cpp each link their own ggml.
//! Loading both in the app process collides, so this client keeps a
//! helper (`talkie-qvac`) alive and sends it 16 kHz mono PCM over a Unix socket.

use anyhow::{anyhow, Context, Result};
use log::info;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Registry id. Matches Handy's `{repo}/{filename}` Hugging Face ids.
pub const MODEL_ID: &str = "qvac/TranscribePsy-250M-EU-sub-gguf/transcribepsy-250m-eu-sub.gguf";
pub const REPO_ID: &str = "qvac/TranscribePsy-250M-EU-sub-gguf";
pub const FILENAME: &str = "transcribepsy-250m-eu-sub.gguf";

/// Languages the published EU-sub checkpoint covers.
pub const LANGUAGES: &[&str] = &["nl", "en", "fr", "de", "it", "pl", "pt", "es"];

const OP_LOAD: u32 = 1;
const OP_TRANSCRIBE: u32 = 2;
const OP_UNLOAD: u32 = 3;
const OP_QUIT: u32 = 4;

const MAX_PAYLOAD: usize = 256 * 1024 * 1024;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const HELPER_NAME: &str = "talkie-qvac-aarch64-apple-darwin";
#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
const HELPER_NAME: &str = "talkie-qvac-x86_64-apple-darwin";
#[cfg(not(target_os = "macos"))]
const HELPER_NAME: &str = "talkie-qvac";

pub fn is_qvac_model(model_id: &str) -> bool {
    model_id == MODEL_ID || model_id.contains("transcribepsy")
}

pub struct QvacClient {
    socket_path: PathBuf,
    child: Mutex<Option<Child>>,
    stream: Mutex<Option<UnixStream>>,
    logs: Mutex<Option<JoinHandle<()>>>,
    loaded: AtomicBool,
    backend: Mutex<String>,
}

impl QvacClient {
    pub fn new() -> Self {
        Self {
            socket_path: std::env::temp_dir()
                .join(format!("talkie-qvac-{}.sock", std::process::id())),
            child: Mutex::new(None),
            stream: Mutex::new(None),
            logs: Mutex::new(None),
            loaded: AtomicBool::new(false),
            backend: Mutex::new(String::new()),
        }
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded.load(Ordering::Acquire)
    }

    pub fn backend(&self) -> Option<String> {
        let backend = self.backend.lock().unwrap().clone();
        (!backend.is_empty()).then_some(backend)
    }

    pub fn load(&self, model_path: &Path) -> Result<String> {
        let path = model_path
            .to_str()
            .ok_or_else(|| anyhow!("model path is not UTF-8: {}", model_path.display()))?
            .as_bytes();
        let backend = self.call(OP_LOAD, path, Duration::from_secs(180))?;
        self.loaded.store(true, Ordering::Release);
        *self.backend.lock().unwrap() = backend.clone();
        info!("QVAC model loaded on {backend}");
        Ok(backend)
    }

    pub fn unload(&self) -> Result<()> {
        if !self.is_loaded() {
            return Ok(());
        }
        match self.call(OP_UNLOAD, &[], Duration::from_secs(30)) {
            Ok(_) => {
                self.loaded.store(false, Ordering::Release);
                self.backend.lock().unwrap().clear();
                Ok(())
            }
            Err(error) => {
                self.loaded.store(false, Ordering::Release);
                self.backend.lock().unwrap().clear();
                Err(error)
            }
        }
    }

    pub fn transcribe(&self, samples: &[f32]) -> Result<String> {
        if !self.is_loaded() {
            return Err(anyhow!("QVAC model is not loaded"));
        }
        let mut payload = Vec::with_capacity(samples.len() * 4);
        for sample in samples {
            payload.extend_from_slice(&sample.to_le_bytes());
        }
        let audio_secs = samples.len() as f64 / 16_000.0;
        let timeout = Duration::from_secs_f64((audio_secs * 4.0).max(120.0).min(600.0));
        self.call(OP_TRANSCRIBE, &payload, timeout)
    }

    fn call(&self, op: u32, payload: &[u8], timeout: Duration) -> Result<String> {
        self.ensure()?;
        let mut guard = self.stream.lock().unwrap();
        let stream = guard
            .as_mut()
            .ok_or_else(|| anyhow!("QVAC helper is not connected"))?;
        stream
            .set_read_timeout(Some(timeout))
            .context("failed to set QVAC helper read timeout")?;
        stream
            .set_write_timeout(Some(Duration::from_secs(30)))
            .context("failed to set QVAC helper write timeout")?;
        if let Err(error) = write_message(stream, op, payload) {
            *guard = None;
            self.loaded.store(false, Ordering::Release);
            return Err(error);
        }
        match read_message(stream) {
            Ok((0, bytes)) => String::from_utf8(bytes).context("QVAC helper returned non-UTF-8"),
            Ok((_, bytes)) => Err(anyhow!("{}", String::from_utf8_lossy(&bytes).trim())),
            Err(error) => {
                *guard = None;
                self.loaded.store(false, Ordering::Release);
                Err(error)
            }
        }
    }

    fn ensure(&self) -> Result<()> {
        let running = {
            let mut child = self.child.lock().unwrap();
            match child.as_mut() {
                Some(child) => matches!(child.try_wait(), Ok(None)),
                None => false,
            }
        };
        if !running {
            self.stop_child();
            self.spawn()?;
        }

        let mut stream = self.stream.lock().unwrap();
        if stream.is_some() {
            return Ok(());
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut last_error = None;
        while Instant::now() < deadline {
            if let Some(child) = self.child.lock().unwrap().as_mut() {
                if let Ok(Some(status)) = child.try_wait() {
                    return Err(anyhow!("QVAC helper exited before it was ready ({status})"));
                }
            }
            match UnixStream::connect(&self.socket_path) {
                Ok(connected) => {
                    *stream = Some(connected);
                    return Ok(());
                }
                Err(error) => {
                    last_error = Some(error);
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
        Err(anyhow!(
            "QVAC helper did not open {}: {}",
            self.socket_path.display(),
            last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "no connection".to_string())
        ))
    }

    fn spawn(&self) -> Result<()> {
        let binary = helper_binary()?;
        info!("Starting QVAC helper at {}", binary.display());
        let _ = std::fs::remove_file(&self.socket_path);
        let mut child = Command::new(&binary)
            .arg("--socket")
            .arg(&self.socket_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("failed to start {}", binary.display()))?;
        if let Some(stderr) = child.stderr.take() {
            let handle = std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    match line {
                        Ok(line) => info!("qvac: {line}"),
                        Err(_) => break,
                    }
                }
            });
            *self.logs.lock().unwrap() = Some(handle);
        }
        *self.child.lock().unwrap() = Some(child);
        Ok(())
    }

    fn stop_child(&self) {
        if let Some(stream) = self.stream.lock().unwrap().as_mut() {
            let _ = write_message(stream, OP_QUIT, &[]);
        }
        self.stream.lock().unwrap().take();
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(handle) = self.logs.lock().unwrap().take() {
            let _ = handle.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
        self.loaded.store(false, Ordering::Release);
    }
}

impl Drop for QvacClient {
    fn drop(&mut self) {
        if let Ok(mut stream) = self.stream.lock() {
            if let Some(stream) = stream.as_mut() {
                let _ = write_message(stream, OP_QUIT, &[]);
            }
        }
        if let Ok(mut child) = self.child.lock() {
            if let Some(mut child) = child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        if let Ok(mut logs) = self.logs.lock() {
            if let Some(handle) = logs.take() {
                let _ = handle.join();
            }
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

fn helper_binary() -> Result<PathBuf> {
    if let Ok(path) = std::env::var("TALKIE_QVAC_HELPER") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
        return Err(anyhow!(
            "TALKIE_QVAC_HELPER is not a file: {}",
            path.display()
        ));
    }

    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join(HELPER_NAME));
            candidates.push(dir.join("talkie-qvac"));
        }
    }
    candidates.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("binaries")
            .join(HELPER_NAME),
    );
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .with_context(|| {
            format!(
                "QVAC helper ({HELPER_NAME}) was not found next to Talkie-Talk. Run scripts/build-qvac-helper.sh"
            )
        })
}

fn write_message(stream: &mut UnixStream, op: u32, payload: &[u8]) -> Result<()> {
    if payload.len() > MAX_PAYLOAD {
        return Err(anyhow!("QVAC request is too large"));
    }
    let mut header = [0u8; 8];
    header[..4].copy_from_slice(&op.to_le_bytes());
    header[4..].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    stream
        .write_all(&header)
        .context("failed to write to the QVAC helper")?;
    if !payload.is_empty() {
        stream
            .write_all(payload)
            .context("failed to write to the QVAC helper")?;
    }
    stream.flush().context("failed to flush the QVAC helper")?;
    Ok(())
}

fn read_message(stream: &mut UnixStream) -> Result<(u32, Vec<u8>)> {
    let mut header = [0u8; 8];
    stream
        .read_exact(&mut header)
        .context("QVAC helper closed the connection")?;
    let status = u32::from_le_bytes(header[..4].try_into().unwrap());
    let len = u32::from_le_bytes(header[4..].try_into().unwrap()) as usize;
    if len > MAX_PAYLOAD {
        return Err(anyhow!("QVAC helper response is too large"));
    }
    let mut payload = vec![0u8; len];
    if len > 0 {
        stream
            .read_exact(&mut payload)
            .context("QVAC helper closed the connection")?;
    }
    Ok((status, payload))
}

impl Default for QvacClient {
    fn default() -> Self {
        Self::new()
    }
}
