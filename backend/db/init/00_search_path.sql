-- Runs first on a fresh database volume (before the data dump) so every connection finds the fogops schema.
ALTER DATABASE fogops SET search_path = fogops, public;
