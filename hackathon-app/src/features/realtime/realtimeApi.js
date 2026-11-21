import { api } from '@/app/api';
import { socket } from '@/services/socket';
import { uuid } from '@/utils/uuid';

// Pattern: realtime data inside RTK Query. The cache starts empty, then socket events
// are pushed into it, so components just use `useGetMessagesQuery()` like any other data.
export const realtimeApi = api.injectEndpoints({
  endpoints: (build) => ({
    getMessages: build.query({
      queryFn: () => ({ data: [] }),
      async onCacheEntryAdded(_arg, { updateCachedData, cacheDataLoaded, cacheEntryRemoved }) {
        await cacheDataLoaded;
        const off = socket.subscribe('chat', (msg) =>
          updateCachedData((draft) => void draft.push(msg)),
        );
        await cacheEntryRemoved;
        off();
      },
    }),
    sendMessage: build.mutation({
      queryFn: (text) => {
        const ok = socket.send('chat', { id: uuid(), text, at: Date.now() });
        return ok ? { data: null } : { error: { error: 'Socket not connected' } };
      },
    }),
  }),
});

export const { useGetMessagesQuery, useSendMessageMutation } = realtimeApi;
