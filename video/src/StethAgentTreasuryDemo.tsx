import { Audio, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { TransitionSeries, linearTiming } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { slide } from "@remotion/transitions/slide";
import { interpolate } from "remotion";
import { IntroScene } from "./scenes/IntroScene";
import { HowItWorksScene } from "./scenes/HowItWorksScene";
import { TerminalScene } from "./scenes/TerminalScene";
import { ProofScene } from "./scenes/ProofScene";
import { CtaScene } from "./scenes/CtaScene";

export const StethAgentTreasuryDemo: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();

  const musicVolume = interpolate(
    frame,
    [0, 60, durationInFrames - 60, durationInFrames],
    [0, 0.3, 0.3, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
  );

  return (
    <div style={{ background: "#06060f", width: "100%", height: "100%" }}>
      <Audio src={staticFile("music.mp3")} volume={musicVolume} />
      <TransitionSeries>
        {/* Scene 1: Intro — 4s */}
        <TransitionSeries.Sequence durationInFrames={120}>
          <IntroScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade()}
          timing={linearTiming({ durationInFrames: 15 })}
        />
        {/* Scene 2: How It Works — ~6.7s (animations + 3s reading) */}
        <TransitionSeries.Sequence durationInFrames={200}>
          <HowItWorksScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={slide({ direction: "from-right" })}
          timing={linearTiming({ durationInFrames: 15 })}
        />
        {/* Scene 3: Terminal Demo — 7s */}
        <TransitionSeries.Sequence durationInFrames={210}>
          <TerminalScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade()}
          timing={linearTiming({ durationInFrames: 15 })}
        />
        {/* Scene 4: On-Chain Proof — ~5.3s (animations + 2s reading) */}
        <TransitionSeries.Sequence durationInFrames={160}>
          <ProofScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={slide({ direction: "from-bottom" })}
          timing={linearTiming({ durationInFrames: 15 })}
        />
        {/* Scene 5: CTA — ~6.3s (animations + 2s reading) */}
        <TransitionSeries.Sequence durationInFrames={190}>
          <CtaScene />
        </TransitionSeries.Sequence>
      </TransitionSeries>
    </div>
  );
};
