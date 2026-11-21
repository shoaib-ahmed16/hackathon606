// Plain-English rendering of a rule definition (copied from the retired MUI rule dialog).
export const OP_LABEL = {
  eq: 'is',
  neq: 'is not',
  lt: 'is less than',
  lte: 'is at most',
  gt: 'is more than',
  gte: 'is at least',
  in: 'is one of',
  is_null: 'is empty',
  not_null: 'is set',
};

export function describeRule(node, fields) {
  const label = (f) => fields?.find((x) => x.field === f)?.label ?? f;
  if (!node) return '';
  const list = node.all ?? node.any;
  if (list)
    return list
      .map((n) => (n.all || n.any ? `(${describeRule(n, fields)})` : describeRule(n, fields)))
      .join(node.all ? ' AND ' : ' OR ');
  const v = Array.isArray(node.value) ? node.value.join(', ') : String(node.value);
  return `${label(node.field)} ${OP_LABEL[node.op] ?? node.op}${node.op === 'is_null' || node.op === 'not_null' ? '' : ` ${v}`}`;
}
