import { useEffect, useRef, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  Dialog,
  DialogContent,
  DialogTitle,
  InputAdornment,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import SendIcon from '@mui/icons-material/Send';
import { useAppDispatch } from '@/app/hooks';
import { useAskMutation, useGetAskQuestionsQuery } from '@/features/ops/opsApi';
import { closePanel } from '@/features/ops/opsSlice';
import { getErrorMessage } from '@/utils/getErrorMessage';

const MODE = {
  predefined: ['From live data', 'success'],
  ai: ['AI, grounded on case data', 'info'],
  fallback: ['AI not configured', 'warning'],
  error: ['Unavailable', 'error'],
  none: ['', 'default'],
};

// Ctrl+K assistant. Suggested questions are answered from the database; free text goes to Claude (when the key is set)
// with only this case's database facts, so it cannot make flights or times up.
export default function AskDialog({ d }) {
  const dispatch = useAppDispatch();
  const { ctx } = d;
  const [ask, { isLoading }] = useAskMutation();
  const [q, setQ] = useState('');
  const [log, setLog] = useState([]);
  const end = useRef(null);
  const sug = useGetAskQuestionsQuery(ctx);

  useEffect(() => {
    end.current?.scrollIntoView?.({ behavior: 'smooth' });
  }, [log.length]);

  const send = async (text) => {
    const question = (text ?? q).trim();
    if (!question || isLoading) return;
    setQ('');
    try {
      const res = await ask({ question, ...ctx }).unwrap();
      setLog((l) => [...l, { question, ...res }]);
    } catch (e) {
      setLog((l) => [...l, { question, mode: 'error', answer: getErrorMessage(e), source: null }]);
    }
  };

  return (
    <Dialog open onClose={() => dispatch(closePanel())} maxWidth="md" fullWidth>
      <DialogTitle>Ask about this case</DialogTitle>
      <DialogContent>
        <Stack spacing={1.5}>
          {sug.data && !sug.data.ai && (
            <Alert severity="info" sx={{ py: 0 }}>
              Suggested questions work now. Free-text questions need the Claude API key (
              <code>ANTHROPIC_API_KEY</code>) on the server.
            </Alert>
          )}
          <TextField
            autoFocus
            placeholder="Ask about flights, crew, aircraft, deadlines..."
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && send()}
            slotProps={{
              input: {
                endAdornment: (
                  <InputAdornment position="end">
                    <Button
                      size="small"
                      variant="contained"
                      endIcon={<SendIcon />}
                      disabled={!q.trim() || isLoading}
                      onClick={() => send()}
                    >
                      Ask
                    </Button>
                  </InputAdornment>
                ),
              },
            }}
          />
          <Stack direction="row" sx={{ gap: 0.75, flexWrap: 'wrap' }}>
            {(sug.data?.items ?? []).map((s) => (
              <Chip
                key={s}
                size="small"
                variant="outlined"
                label={s}
                onClick={() => send(s)}
                clickable
                disabled={isLoading}
              />
            ))}
          </Stack>
          <Box sx={{ maxHeight: 420, overflow: 'auto', display: 'grid', gap: 1.25 }}>
            {log.map((m, i) => (
              <Paper key={i} variant="outlined" sx={{ p: 1.5 }}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>
                  {m.question}
                </Typography>
                <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap' }}>
                  {m.answer}
                </Typography>
                <Stack direction="row" spacing={1} sx={{ mt: 1, alignItems: 'center' }}>
                  {MODE[m.mode]?.[0] && (
                    <Chip size="small" color={MODE[m.mode][1]} label={MODE[m.mode][0]} />
                  )}
                  {m.source && (
                    <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                      {m.source}
                    </Typography>
                  )}
                </Stack>
              </Paper>
            ))}
            {isLoading && (
              <Typography variant="body2" sx={{ color: 'text.secondary' }}>
                Thinking...
              </Typography>
            )}
            <div ref={end} />
          </Box>
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            The assistant only reads data. It cannot approve, decide or change anything, and every
            question is recorded in the audit trail.
          </Typography>
        </Stack>
      </DialogContent>
    </Dialog>
  );
}
