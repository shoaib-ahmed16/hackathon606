import { Chip, Tooltip } from '@mui/material';
import { OUTCOME, SOURCE } from './capacityHelpers';

// Where a number comes from: status entry (a person, current), assumed (configured), from history, or unknown.
export function SourceChip({ source, basis }) {
  const [label, color] = SOURCE[source] ?? SOURCE.UNKNOWN;
  const chip = (
    <Chip
      size="small"
      label={label}
      color={color}
      variant={color === 'default' ? 'outlined' : 'filled'}
    />
  );
  return basis ? <Tooltip title={basis}>{chip}</Tooltip> : chip;
}

export function OutcomeChip({ outcome, size = 'small' }) {
  const [label, color] = OUTCOME[outcome] ?? OUTCOME.UNKNOWN_VERIFICATION_REQUIRED;
  return (
    <Chip
      size={size}
      label={label}
      color={color}
      variant={color === 'default' ? 'outlined' : 'filled'}
    />
  );
}
