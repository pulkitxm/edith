import {Composition} from 'remotion';
import {Main} from './Main';
import {totalDuration, fps} from './tokens';

export const Root: React.FC = () => {
  return (
    <Composition
      id="Main"
      component={Main}
      durationInFrames={totalDuration}
      fps={fps}
      width={1920}
      height={1080}
    />
  );
};
