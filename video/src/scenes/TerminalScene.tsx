import { useCurrentFrame, interpolate } from "remotion";
import { loadFont } from "@remotion/google-fonts/JetBrainsMono";
import { loadFont as loadInter } from "@remotion/google-fonts/Inter";

const { fontFamily: mono } = loadFont("normal", {
  weights: ["400", "700"],
  subsets: ["latin"],
});
const { fontFamily: inter } = loadInter("normal", {
  weights: ["700"],
  subsets: ["latin"],
});

interface Line {
  text: string;
  color: string;
  delay: number;
}

const lines: Line[] = [
  { text: '[Agent] Prompt: "What is wstETH and how does', color: "#94a3b8", delay: 0 },
  { text: '         Lido staking yield work?"', color: "#94a3b8", delay: 3 },
  { text: "", color: "", delay: 10 },
  { text: "[Agent] Requesting: POST /v1/chat/completions", color: "#94a3b8", delay: 15 },
  { text: "[Agent] Got 402 \u2014 payment required: 0.00001 wstETH", color: "#f59e0b", delay: 28 },
  { text: "[Agent] Claiming yield from treasury...", color: "#94a3b8", delay: 42 },
  { text: "[Agent] Payment tx: 0x07c94d4f...bef449", color: "#7b3fe4", delay: 55 },
  { text: "[Agent] Confirmed in block 43719167 (success)", color: "#22c55e", delay: 68 },
  { text: "[Agent] Retrying with payment credential...", color: "#94a3b8", delay: 82 },
  { text: '[Agent] Payment receipt: method="wsteth-yield"', color: "#22c55e", delay: 95 },
  { text: "", color: "", delay: 105 },
  { text: "\u250C\u2500\u2500 AI Response \u2500\u2500", color: "#64748b", delay: 110 },
  { text: "  wstETH is a token representing staked ETH", color: "white", delay: 118 },
  { text: "  via Lido, accruing staking rewards...", color: "white", delay: 125 },
  { text: "", color: "", delay: 133 },
  { text: "\u250C\u2500\u2500 Summary \u2500\u2500", color: "#64748b", delay: 140 },
  { text: "  Yield spent:         0.00001 wstETH ($0.026)", color: "#f59e0b", delay: 148 },
  { text: "  Principal unchanged: YES \u2713", color: "#22c55e", delay: 156 },
];

export const TerminalScene: React.FC = () => {
  const frame = useCurrentFrame();

  const windowScale = interpolate(frame, [0, 10], [0.95, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const windowOpacity = interpolate(frame, [0, 10], [0, 1], {
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
        background: "#06060f",
        padding: 40,
      }}
    >
      <div
        style={{
          fontFamily: inter,
          fontSize: 32,
          fontWeight: 700,
          color: "white",
          marginBottom: 24,
          opacity: windowOpacity,
        }}
      >
        {"Live Demo \u2014 Base Mainnet"}
      </div>

      <div
        style={{
          opacity: windowOpacity,
          transform: `scale(${windowScale})`,
          width: 1100,
          background: "#0d1117",
          borderRadius: 16,
          border: "1px solid #1e293b",
          overflow: "hidden",
          boxShadow: "0 20px 60px rgba(0,0,0,0.5)",
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            padding: "12px 16px",
            background: "#161b22",
            borderBottom: "1px solid #1e293b",
          }}
        >
          <div style={{ width: 12, height: 12, borderRadius: "50%", background: "#ff5f57" }} />
          <div style={{ width: 12, height: 12, borderRadius: "50%", background: "#febc2e" }} />
          <div style={{ width: 12, height: 12, borderRadius: "50%", background: "#28c840" }} />
          <span
            style={{
              fontFamily: mono,
              fontSize: 13,
              color: "#64748b",
              marginLeft: 12,
            }}
          >
            {"steth-agent-treasury \u2014 agent.ts"}
          </span>
        </div>

        <div style={{ padding: "16px 20px", minHeight: 420 }}>
          {lines.map((line, i) => {
            const lineOpacity = interpolate(
              frame,
              [line.delay, line.delay + 5],
              [0, 1],
              { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
            );
            const lineY = interpolate(
              frame,
              [line.delay, line.delay + 5],
              [8, 0],
              { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
            );

            if (!line.text) {
              return <div key={i} style={{ height: 8 }} />;
            }

            return (
              <div
                key={i}
                style={{
                  opacity: lineOpacity,
                  transform: `translateY(${lineY}px)`,
                  fontFamily: mono,
                  fontSize: 16,
                  color: line.color,
                  lineHeight: 1.7,
                  whiteSpace: "pre",
                }}
              >
                {line.text}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
};
