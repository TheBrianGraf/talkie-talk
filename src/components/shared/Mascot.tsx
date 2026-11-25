import React from "react";
import TalkieMark from "../icons/TalkieMark";

interface MascotProps {
  /** Height in px. */
  size: number;
  /** Wave once on arrival, or high-five (re-key it to play again). */
  animation?: "wave" | "slap" | null;
}

/** Talkie-Talk's speech-bubble mark, optionally animated. */
export const Mascot: React.FC<MascotProps> = ({ size, animation = null }) => (
  <span
    style={{ width: size, height: size }}
    className={`relative flex items-center justify-center origin-[50%_90%] select-none ${animation === "wave" ? "animate-wave" : animation === "slap" ? "animate-slap" : ""}`}
  >
    <TalkieMark size={size} />
  </span>
);
