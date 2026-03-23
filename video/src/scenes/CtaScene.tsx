import { useCurrentFrame, useVideoConfig, interpolate, spring } from "remotion";
import { loadFont } from "@remotion/google-fonts/Inter";
import { loadFont as loadMono } from "@remotion/google-fonts/JetBrainsMono";

const { fontFamily } = loadFont("normal", {
  weights: ["400", "700", "900"],
  subsets: ["latin"],
});
const { fontFamily: mono } = loadMono("normal", {
  weights: ["400"],
  subsets: ["latin"],
});

export const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleScale = spring({ frame, fps, config: { damping: 12, stiffness: 100 } });
  const repoOpacity = interpolate(frame, [15, 30], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const badgesOpacity = interpolate(frame, [30, 45], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const brandOpacity = interpolate(frame, [45, 60], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const glowPulse = interpolate(frame % 60, [0, 30, 60], [0.3, 0.6, 0.3]);

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
      {/* Background glow */}
      <div
        style={{
          position: "absolute",
          width: 700,
          height: 700,
          borderRadius: "50%",
          background: `radial-gradient(circle, rgba(0,163,255,${glowPulse * 0.2}) 0%, rgba(123,63,228,${glowPulse * 0.1}) 50%, transparent 70%)`,
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
        }}
      />

      <div
        style={{
          transform: `scale(${titleScale})`,
          fontSize: 48,
          fontWeight: 900,
          color: "white",
          marginBottom: 24,
          textAlign: "center",
        }}
      >
        Yield-Funded AI Agents
      </div>

      <div
        style={{
          opacity: repoOpacity,
          fontFamily: mono,
          fontSize: 22,
          color: "#00a3ff",
          background: "#0d1117",
          padding: "14px 32px",
          borderRadius: 12,
          border: "1px solid #00a3ff30",
          marginBottom: 32,
        }}
      >
        github.com/kmadorin/lido-steth-agent-treasury
      </div>

      {/* Badges */}
      <div
        style={{
          opacity: badgesOpacity,
          display: "flex",
          gap: 20,
          marginBottom: 40,
        }}
      >
        {[
          { text: "49 Tests", color: "#22c55e" },
          { text: "Base Mainnet", color: "#00a3ff" },
          { text: "MPP Protocol", color: "#f59e0b" },
          { text: "Sourcify Verified", color: "#7b3fe4" },
        ].map((badge, i) => (
          <div
            key={i}
            style={{
              fontSize: 16,
              fontWeight: 700,
              color: badge.color,
              background: `${badge.color}15`,
              border: `1px solid ${badge.color}40`,
              padding: "8px 20px",
              borderRadius: 20,
            }}
          >
            {badge.text}
          </div>
        ))}
      </div>

      {/* Hackathon + Lido */}
      <div
        style={{
          opacity: brandOpacity,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          gap: 8,
        }}
      >
        <div style={{ fontSize: 20, color: "#94a3b8" }}>
          {"Built for Synthesis Hackathon \u00B7 Lido stETH Bounty"}
        </div>
        <div style={{ fontSize: 16, color: "#475569" }}>
          Principal stays locked. Agent spends only yield. Verified on-chain.
        </div>
      </div>
    </div>
  );
};
