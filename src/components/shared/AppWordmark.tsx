/** The product name. Matches `productName` in `src-tauri/tauri.conf.json`. */
export const APP_NAME = "Talkie-Talk";

/** The app name as text in the wordmark color, wrapping onto two lines when narrow. */
const AppWordmark = ({
  width,
  className = "",
}: {
  width?: number;
  className?: string;
}) => {
  return (
    <div
      style={{ width }}
      className={`text-center text-base font-bold leading-tight text-wordmark ${className}`}
    >
      {APP_NAME}
    </div>
  );
};

export default AppWordmark;
