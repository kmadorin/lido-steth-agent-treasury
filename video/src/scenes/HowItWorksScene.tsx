import { useCurrentFrame, useVideoConfig, interpolate, spring } from "remotion";
import { loadFont } from "@remotion/google-fonts/Inter";

const { fontFamily } = loadFont("normal", {
  weights: ["400", "700", "900"],
  subsets: ["latin"],
});

const steps = [
  { icon: "\uD83D\uDD12", label: "Human deposits wstETH", sub: "Principal locked forever", color: "#00a3ff" },
  { icon: "\uD83D\uDCC8", label: "Yield accrues via staking", sub: "~3.5% APR from Lido", color: "#7b3fe4" },
  { icon: "\uD83E\uDD16", label: "Agent spends only yield", sub: "Pays for API calls via MPP", color: "#f59e0b" },
  { icon: "\u2705", label: "Principal untouched", sub: "Verified on-chain", color: "#22c55e" },
];

export const HowItWorksScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const headerOpacity = interpolate(frame, [0, 15], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

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
        padding: 60,
      }}
    >
      <div
        style={{
          opacity: headerOpacity,
          fontSize: 44,
          fontWeight: 900,
          color: "white",
          marginBottom: 60,
        }}
      >
        How It Works
      </div>

      <div style={{ display: "flex", gap: 40, alignItems: "center" }}>
        {steps.map((step, i) => {
          const s = spring({
            frame,
            fps,
            config: { damping: 12, stiffness: 150 },
            delay: 15 + i * 12,
          });
          const arrowOpacity = interpolate(frame, [25 + i * 12, 35 + i * 12], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          });

          return (
            <div key={i} style={{ display: "flex", alignItems: "center", gap: 30 }}>
              <div
                style={{
                  transform: `scale(${s})`,
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  width: 200,
                  textAlign: "center",
                }}
              >
                <div
                  style={{
                    width: 80,
                    height: 80,
                    borderRadius: 20,
                    background: `${step.color}20`,
                    border: `2px solid ${step.color}40`,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    fontSize: 36,
                    marginBottom: 16,
                  }}
                >
                  {step.icon}
                </div>
                <div
                  style={{
                    fontSize: 18,
                    fontWeight: 700,
                    color: "white",
                    marginBottom: 6,
                  }}
                >
                  {step.label}
                </div>
                <div style={{ fontSize: 14, color: "#64748b" }}>{step.sub}</div>
              </div>
              {i < steps.length - 1 && (
                <div
                  style={{
                    opacity: arrowOpacity,
                    fontSize: 28,
                    color: "#334155",
                  }}
                >
                  {"\u2192"}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
};
