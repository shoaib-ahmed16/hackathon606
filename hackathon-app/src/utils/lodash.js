// Lodash, tree-shaken (lodash-es). Import straight from 'lodash-es' anywhere:
//   import { sumBy, groupBy, orderBy, debounce, get, pick, omit, uniqBy, chunk, isEmpty } from 'lodash-es';
// Cheat sheet for the usual hackathon needs:
//   sumBy(items, 'price')            meanBy(items, 'score')        maxBy / minBy
//   groupBy(items, 'category')       countBy(items, 'status')      keyBy(items, 'id')
//   orderBy(items, ['age','name'], ['desc','asc'])                 uniqBy(items, 'id')
//   pick(obj, ['a','b'])  omit(obj, ['x'])  get(obj, 'a.b.c', fallback)  set / merge / cloneDeep
//   chunk(arr, 3)  flatten  difference  intersection  range(1, 6)  sampleSize  shuffle
//   isEmpty(x)  isEqual(a, b)  debounce(fn, 300)  throttle(fn, 1000)  capitalize / camelCase / startCase / truncate
// (Re-exporting a few so `@/utils/lodash` also works.)
export {
  sumBy,
  meanBy,
  maxBy,
  minBy,
  groupBy,
  countBy,
  keyBy,
  orderBy,
  uniqBy,
  pick,
  omit,
  get,
  set,
  merge,
  cloneDeep,
  chunk,
  flatten,
  difference,
  intersection,
  range,
  isEmpty,
  isEqual,
  debounce,
  throttle,
  capitalize,
  camelCase,
  startCase,
  truncate,
} from 'lodash-es';
