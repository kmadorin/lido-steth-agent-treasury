import { useCurrentFrame, useVideoConfig, interpolate, spring } from "remotion";
import { loadFont } from "@remotion/google-fonts/Inter";

const { fontFamily } = loadFont("normal", {
  weights: ["400", "700", "900"],
  subsets: ["latin"],
});

export const IntroScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleScale = spring({ frame: frame + 5, fps, config: { damping: 12, stiffness: 100 } });
  const subtitleOpacity = interpolate(frame, [15, 30], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const subtitleY = interpolate(frame, [15, 30], [20, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const taglineOpacity = interpolate(frame, [30, 50], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const glowPulse = interpolate(frame % 60, [0, 30, 60], [0.4, 0.7, 0.4]);

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        fontFamily,
        background: "#06060f",
        position: "relative",
        overflow: "hidden",
      }}
    >
      <div
        style={{
          position: "absolute",
          width: 600,
          height: 600,
          borderRadius: "50%",
          background: `radial-gradient(circle, rgba(0,163,255,${glowPulse * 0.3}) 0%, transparent 70%)`,
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
        }}
      />

      <div
        style={{
          transform: `scale(${titleScale})`,
          marginBottom: 20,
        }}
      >
        <div
          style={{
            width: 100,
            height: 100,
            borderRadius: "50%",
            background: "linear-gradient(135deg, #00a3ff, #7b3fe4)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 50,
            color: "white",
            fontWeight: 900,
            boxShadow: "0 0 40px rgba(0,163,255,0.5)",
          }}
        >
          {"\u039E"}
        </div>
      </div>

      <div
        style={{
          transform: `scale(${titleScale})`,
          fontSize: 72,
          fontWeight: 900,
          color: "white",
          letterSpacing: -2,
        }}
      >
        stETH Agent Treasury
      </div>

      <div
        style={{
          opacity: subtitleOpacity,
          transform: `translateY(${subtitleY}px)`,
          fontSize: 28,
          color: "#00a3ff",
          fontWeight: 700,
          marginTop: 16,
        }}
      >
        AI agents pay for services with staking yield
      </div>

      <div
        style={{
          opacity: taglineOpacity,
          fontSize: 20,
          color: "#94a3b8",
          fontWeight: 400,
          marginTop: 12,
        }}
      >
        {"Principal locked \u00B7 Yield flows \u00B7 Deployed on Base"}
      </div>
    </div>
  );
};
