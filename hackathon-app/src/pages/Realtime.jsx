import { useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Chip, List, ListItem, ListItemText, Paper, Stack, TextField } from '@mui/material';
import SendIcon from '@mui/icons-material/Send';
import { useAppSelector } from '@/app/hooks';
import { selectSocketStatus } from '@/features/socket/socketSlice';
import { useGetMessagesQuery, useSendMessageMutation } from '@/features/realtime/realtimeApi';
import EmptyState from '@/components/EmptyState';
import PageHeader from '@/components/PageHeader';
import { getErrorMessage } from '@/utils/getErrorMessage';

const statusColor = { connected: 'success', connecting: 'warning', disconnected: 'error' };

// WebSocket demo (echo server: whatever you send comes back).
export default function Realtime() {
  const status = useAppSelector(selectSocketStatus);
  const { data: messages = [] } = useGetMessagesQuery();
  const [send, { isLoading }] = useSendMessageMutation();
  const [text, setText] = useState('');

  const onSend = async (e) => {
    e.preventDefault();
    try {
      await send(text).unwrap();
      setText('');
    } catch (err) {
      toast.error(getErrorMessage(err));
    }
  };

  return (
    <Stack spacing={2}>
      <PageHeader
        title="Realtime"
        subtitle="WebSocket demo (echo server)"
        actions={<Chip size="small" label={status} color={statusColor[status]} />}
      />
      <Paper sx={{ minHeight: 240 }}>
        <List>
          {messages.map((m) => (
            <ListItem key={m.id} divider>
              <ListItemText primary={m.text} secondary={new Date(m.at).toLocaleTimeString()} />
            </ListItem>
          ))}
          {!messages.length && <EmptyState title="No messages yet" hint="Send one below" />}
        </List>
      </Paper>
      <Stack component="form" onSubmit={onSend} direction="row" spacing={1}>
        <TextField
          placeholder="Type a message"
          required
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
        <Button
          type="submit"
          variant="contained"
          endIcon={<SendIcon />}
          disabled={isLoading || status !== 'connected'}
        >
          Send
        </Button>
      </Stack>
    </Stack>
  );
}
