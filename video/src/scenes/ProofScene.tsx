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

const txs = [
  { label: "Payment (claimYield)", hash: "0x07c94d4f...bef449", color: "#f59e0b" },
  { label: "Deposit", hash: "0x2ec4eede...e2f4b7", color: "#00a3ff" },
  { label: "TopUpYield", hash: "0x9112b6de...a86cab", color: "#7b3fe4" },
  { label: "Whitelist Server", hash: "0xc5c8f110...446543", color: "#22c55e" },
];

export const ProofScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const headerScale = spring({ frame, fps, config: { damping: 12, stiffness: 100 } });
  const checkScale = spring({ frame, fps, config: { damping: 8, stiffness: 200 }, delay: 15 });

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
          width: 500,
          height: 500,
          borderRadius: "50%",
          background: "radial-gradient(circle, rgba(34,197,94,0.15) 0%, transparent 70%)",
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
        }}
      />

      <div
        style={{
          transform: `scale(${headerScale})`,
          fontSize: 44,
          fontWeight: 900,
          color: "white",
          marginBottom: 8,
        }}
      >
        Verified on Base Mainnet
      </div>

      <div
        style={{
          transform: `scale(${checkScale})`,
          fontSize: 64,
          marginBottom: 30,
        }}
      >
        {"\u2705"}
      </div>

      <div
        style={{
          opacity: interpolate(frame, [20, 30], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          fontFamily: mono,
          fontSize: 18,
          color: "#64748b",
          background: "#0d1117",
          padding: "10px 24px",
          borderRadius: 10,
          border: "1px solid #1e293b",
          marginBottom: 40,
        }}
      >
        Treasury: 0x6DE964cD52cedb8D8FbD9BFE4c07f35c3cc9c1Ea
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        {txs.map((tx, i) => {
          const s = spring({
            frame,
            fps,
            config: { damping: 15, stiffness: 200 },
            delay: 25 + i * 8,
          });
          return (
            <div
              key={i}
              style={{
                transform: `scale(${s})`,
                display: "flex",
                alignItems: "center",
                gap: 16,
                background: "#0d1117",
                padding: "10px 24px",
                borderRadius: 10,
                border: `1px solid ${tx.color}30`,
                minWidth: 500,
              }}
            >
              <div
                style={{
                  width: 8,
                  height: 8,
                  borderRadius: "50%",
                  background: tx.color,
                  boxShadow: `0 0 10px ${tx.color}`,
                }}
              />
              <div style={{ fontSize: 16, fontWeight: 700, color: "white", flex: 1 }}>
                {tx.label}
              </div>
              <div style={{ fontFamily: mono, fontSize: 14, color: "#64748b" }}>
                {tx.hash}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
