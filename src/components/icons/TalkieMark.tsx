const BUBBLE =
  "M 232 150 H 792 A 168 168 0 0 1 960 318 V 560 A 168 168 0 0 1 792 728 H 470 L 300 900 Q 276 924 276 890 V 728 H 232 A 168 168 0 0 1 64 560 V 318 A 168 168 0 0 1 232 150 Z";

const BARS = [0.26, 0.5, 0.8, 0.5, 0.26];

/** The Talkie-Talk mark: a speech bubble holding a sound wave. */
const TalkieMark = ({
  width,
  height,
  size = 24,
  className = "",
}: {
  width?: number | string;
  height?: number | string;
  size?: number | string;
  className?: string;
}) => (
  <svg
    width={width ?? size}
    height={height ?? size}
    viewBox="40 130 940 810"
    className={className}
    xmlns="http://www.w3.org/2000/svg"
    aria-hidden="true"
  >
    <path d={BUBBLE} fill="var(--color-logo-primary)" />
    {BARS.map((h, i) => (
      <rect
        key={i}
        x={232 + i * 140}
        y={440 - (h * 400) / 2}
        width={84}
        height={h * 400}
        rx={42}
        fill="#fff"
      />
    ))}
  </svg>
);

export default TalkieMark;
