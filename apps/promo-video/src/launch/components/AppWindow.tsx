import React from 'react';
import {ink, text} from '../theme';
import {Icon} from './Icon';
import {NotchMark} from './NotchMark';

type NavItem = {label: string; icon: string; child?: boolean; badge?: string};

const nav: NavItem[] = [
  {label: 'Home', icon: 'home'},
  {label: 'Agents & Terminal', icon: 'suiteAgents'},
  {label: 'Usage', icon: 'usage', child: true},
  {label: 'Agents', icon: 'herdr', child: true, badge: '3 working'},
  {label: 'Code Review', icon: 'quinjet', child: true},
  {label: 'Machines', icon: 'machines', child: true},
  {label: 'Mac Utilities', icon: 'suiteUtilities'},
  {label: 'Desk', icon: 'suiteDesk'},
  {label: 'Media', icon: 'suiteMedia'},
  {label: 'Studio', icon: 'studio', child: true},
  {label: 'Downloads', icon: 'downloads', child: true},
  {label: 'Music', icon: 'music', child: true},
  {label: 'Developer & Data', icon: 'suiteDeveloper'},
  {label: 'Code Stats', icon: 'codeStats', child: true},
  {label: 'Attention', icon: 'attention', child: true},
];

const footer: NavItem[] = [
  {label: 'Extensions', icon: 'puzzle'},
  {label: 'Settings', icon: 'filters'},
  {label: 'About', icon: 'info'},
];

const accent = ink.coral;

const Row: React.FC<{item: NavItem; active: boolean}> = ({item, active}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 12,
      height: 34,
      padding: item.child ? '0 12px 0 30px' : '0 12px',
      borderRadius: 8,
      background: active ? 'rgba(224,138,106,0.2)' : 'transparent',
      color: active ? ink.text : item.child ? '#d6d6da' : ink.text,
      fontWeight: item.child ? 500 : 600,
      fontSize: 15,
    }}
  >
    <Icon name={item.icon} size={17} color={active ? accent : '#a5a5aa'} />
    <span style={{flex: 1}}>{item.label}</span>
    {item.badge ? <span style={{fontSize: 12, color: accent}}>{item.badge}</span> : null}
  </div>
);

export const AppWindow: React.FC<{
  active: string;
  title: string;
  width?: number;
  height?: number;
  actions?: React.ReactNode;
  children: React.ReactNode;
}> = ({active, title, width = 1560, height = 900, actions, children}) => (
  <div
    style={{
      width,
      height,
      borderRadius: 22,
      overflow: 'hidden',
      display: 'flex',
      background: '#141417',
      border: '1px solid rgba(255,255,255,0.1)',
      boxShadow: '0 60px 160px rgba(0,0,0,0.6), 0 0 0 1px rgba(0,0,0,0.6)',
      fontFamily: text,
      color: ink.text,
    }}
  >
    <div
      style={{
        width: 290,
        background: '#2f2f31',
        borderRight: '1px solid rgba(0,0,0,0.4)',
        padding: '18px 12px',
        display: 'flex',
        flexDirection: 'column',
        gap: 2,
      }}
    >
      <div style={{display: 'flex', alignItems: 'center', gap: 9, padding: '0 8px 18px'}}>
        {['#ff5f57', '#febc2e', '#28c840'].map((c) => (
          <div key={c} style={{width: 13, height: 13, borderRadius: 7, background: c}} />
        ))}
        <div style={{width: 18}} />
        <NotchMark size={22} tile={false} />
        <span style={{fontSize: 15, fontWeight: 600, color: '#d6d6da'}}>Edith</span>
      </div>
      {nav.map((item) => (
        <Row key={item.label} item={item} active={item.label === active} />
      ))}
      <div style={{flex: 1}} />
      <div style={{fontSize: 12, color: ink.textFaint, padding: '0 12px 6px'}}>App</div>
      {footer.map((item) => (
        <Row key={item.label} item={item} active={item.label === active} />
      ))}
      <div
        style={{
          marginTop: 10,
          padding: '0 12px',
          fontSize: 12,
          color: ink.textFaint,
          display: 'flex',
          alignItems: 'center',
          gap: 7,
        }}
      >
        <div style={{width: 7, height: 7, borderRadius: 4, background: ink.green}} />
        <span style={{color: '#d6d6da', fontWeight: 600}}>background</span>
        <span>2 jobs · 0.3% CPU</span>
      </div>
    </div>
    <div style={{flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0}}>
      <div style={{display: 'flex', alignItems: 'center', padding: '30px 36px 18px'}}>
        <div style={{fontSize: 32, fontWeight: 700, letterSpacing: '-0.02em', flex: 1}}>{title}</div>
        {actions}
      </div>
      <div style={{flex: 1, position: 'relative', overflow: 'hidden'}}>{children}</div>
    </div>
  </div>
);
