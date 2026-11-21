---
name: utils-helpers
description: Ready-made helpers for array/object calculations (lodash-es), dates (date-fns), number/currency formatting, and validation rules (zod). Use when doing sums, grouping, sorting, filtering, formatting values, or any data massaging -- don't hand-roll it.
---

# Utility toolbox

- **Lodash** (`lodash-es`, tree-shaken): `import { sumBy, groupBy, orderBy, uniqBy, keyBy, pick, omit, get, chunk, isEmpty, debounce } from 'lodash-es';`
  Cheat sheet at the top of `src/utils/lodash.js` (also re-exported from `@/utils/lodash`).
  ```js
  sumBy(cart, (i) => i.price * i.qty)      groupBy(orders, 'status')       orderBy(users, ['age'], ['desc'])
  meanBy(items, 'score')                   countBy(tasks, 'done')          pick(user, ['id','name'])
  ```
- **Formatting** `src/utils/format.js`: `formatDate`, `formatDateTime`, `timeAgo` (date-fns), `formatNumber`, `formatCompact`, `formatCurrency`, `formatPercent` (Intl). Use in tables/cards instead of raw values.
- **Dates**: `import { addDays, differenceInDays, isBefore, startOfWeek, format } from 'date-fns';`
- **Validation**: zod schemas + `src/utils/validators.js` (see the `forms` skill).
- **Debounce search input**: `useDebounce(value)` hook from `@/hooks/useDebounce`.
- Prefer these over writing reduce/sort/format code by hand; add new shared helpers to `src/utils/` (one file per concern).
