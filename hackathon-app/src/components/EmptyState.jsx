import { Box, Typography } from '@mui/material';
import InboxIcon from '@mui/icons-material/Inbox';

// <EmptyState title="No orders yet" hint="Create your first order" action={<Button>New</Button>} />
export default function EmptyState({ title = 'Nothing here yet', hint, action }) {
  return (
    <Box sx={{ py: 6, textAlign: 'center', color: 'text.secondary' }}>
      <InboxIcon sx={{ fontSize: 40, mb: 1 }} />
      <Typography variant="subtitle1" sx={{ color: 'text.primary' }}>
        {title}
      </Typography>
      {hint && <Typography variant="body2">{hint}</Typography>}
      {action && <Box sx={{ mt: 2 }}>{action}</Box>}
    </Box>
  );
}
