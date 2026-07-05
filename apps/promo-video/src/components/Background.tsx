import React from 'react';
import {AbsoluteFill} from 'remotion';
import {colors} from '../tokens';

export const Background: React.FC<{children: React.ReactNode}> = ({
  children,
}) => (
  <AbsoluteFill
    style={{
      background: colors.bgVignette,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
    }}
  >
    {children}
  </AbsoluteFill>
);
