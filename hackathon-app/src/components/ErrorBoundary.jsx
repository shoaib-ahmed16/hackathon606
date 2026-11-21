import { Component } from 'react';
import { Box, Button, Typography } from '@mui/material';

export default class ErrorBoundary extends Component {
  state = { hasError: false };
  static getDerivedStateFromError() {
    return { hasError: true };
  }
  render() {
    if (!this.state.hasError) return this.props.children;
    return (
      <Box sx={{ p: 6, textAlign: 'center' }}>
        <Typography variant="h5" gutterBottom>
          Something broke 😬
        </Typography>
        <Button onClick={() => location.reload()}>Reload</Button>
      </Box>
    );
  }
}
