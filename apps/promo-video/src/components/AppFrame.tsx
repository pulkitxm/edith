import React from 'react';
import {colors, fontFamily} from '../tokens';
import {TabPill} from './TabPill';

export const AppFrame: React.FC<{
  activeIndex: number;
  width?: number;
  children: React.ReactNode;
}> = ({activeIndex, width = 720, children}) => {
  return (
    <div
      style={{
        width,
        borderRadius: 28,
        background: colors.panel,
        border: `1px solid ${colors.border}`,
        boxShadow: '0 40px 120px rgba(0,0,0,0.55)',
        overflow: 'hidden',
        fontFamily,
      }}
    >
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '28px 32px 20px',
        }}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: 14}}>
          <div
            style={{
              width: 34,
              height: 34,
              borderRadius: 10,
              background:
                'linear-gradient(135deg, #2b3a3d 0%, #16211f 100%)',
            }}
          />
          <span
            style={{
              color: colors.textDim,
              fontSize: 16,
              fontWeight: 600,
              letterSpacing: 3,
            }}
          >
            EDITH
          </span>
        </div>
        <div style={{display: 'flex', gap: 18, color: colors.textDim, fontSize: 20}}>
          <span>&#9881;</span>
          <span>&#9211;</span>
        </div>
      </div>

      <div style={{padding: '0 24px 24px'}}>
        <div style={{background: 'rgba(255,255,255,0.06)', borderRadius: 26, padding: 3}}>
          <TabPill activeIndex={activeIndex} />
        </div>
      </div>

      <div style={{padding: '4px 40px 44px', minHeight: 420}}>{children}</div>
    </div>
  );
};

export const SectionLabel: React.FC<{children: React.ReactNode}> = ({
  children,
}) => (
  <div
    style={{
      color: colors.label,
      fontSize: 13,
      letterSpacing: 2,
      fontWeight: 600,
      marginBottom: 20,
    }}
  >
    {children}
  </div>
);
