import { Composition } from "remotion";
import { StethAgentTreasuryDemo } from "./StethAgentTreasuryDemo";

export const Root: React.FC = () => {
  return (
    <Composition
      id="StethAgentTreasuryDemo"
      component={StethAgentTreasuryDemo}
      durationInFrames={820}
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
