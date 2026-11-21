import { Link } from 'react-router-dom';
import { Box, Button, Typography } from '@mui/material';

export default function NotFound() {
  return (
    <Box sx={{ p: 8, textAlign: 'center' }}>
      <Typography variant="h3">404</Typography>
      <Button component={Link} to="/" sx={{ mt: 2 }}>
        Go home
      </Button>
    </Box>
  );
}
