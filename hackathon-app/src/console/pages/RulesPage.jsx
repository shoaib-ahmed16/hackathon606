import { useNavigate } from 'react-router-dom';
import toast from 'react-hot-toast';
import { useApproveRuleMutation, useGetRuleFieldsQuery, useRejectRuleMutation, useRetireRuleMutation } from '@/features/ops/opsApi';
import { ruleKey } from '@/features/ops/boardFilters';
import { ms } from '@/features/ops/helpers';
import { fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { useConsole } from '../ConsoleContext';
import { Empty, Pill } from '../ui/ui';
import { describeRule } from './ruleDescribe';
import NewRuleForm from './NewRuleForm';
import './pages.css';

const KIND_TONE = { FILTER: 'ai', ALERT: 'risk', PRIORITY: 'disc', CONSTRAINT: 'exceeded' };

function statusOf(x) {
  if (x.status === 'DRAFT') return { tone: 'risk', text: 'Needs approval' };
  if (x.in_force) return { tone: 'legal', text: 'In force' };
  const e = String(x.effective_status ?? x.status);
  return { tone: 'neutral', text: e.charAt(0) + e.slice(1).toLowerCase() };
}

export default function RulesPage() {
  const d = useConsole();
  const navigate = useNavigate();
  const fields = useGetRuleFieldsQuery().data?.fields;
  const [approve] = useApproveRuleMutation();
  const [reject] = useRejectRuleMutation();
  const [retire] = useRetireRuleMutation();

  const run = async (fn, x, ok) => {
    try {
      await fn({ id: x.rule_id }).unwrap();
      toast.success(ok);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <div className="page">
      <h2>Rules and filters</h2>
      <p className="lead">
        Custom rules for a time window. Filters and alerts change what you see and who is told. Priority rules change the order.{' '}
        <b>Constraint rules can only tighten limits</b>; they never relax the approved FDP rules, and they need approval.
      </p>
      {d.rules.length === 0 ? (
        <Empty>No rules yet. Create one below, for example "Pilots not LVP-qualified"; filters appear as chips on the board.</Empty>
      ) : (
        <div className="tbl-wrap">
          <table className="tbl">
            <thead>
              <tr><th>Rule</th><th>Kind</th><th>Condition</th><th>Priority</th><th>Valid</th><th>Status</th><th></th></tr>
            </thead>
            <tbody>
              {d.rules.map((x) => {
                const st = statusOf(x);
                return (
                  <tr key={x.rule_id}>
                    <td>
                      <b>{x.name}</b>
                      <div className="k">by {x.created_by_name}</div>
                    </td>
                    <td><Pill tone={KIND_TONE[x.kind] ?? 'neutral'}>{x.kind}</Pill></td>
                    <td><code>{describeRule(x.definition, fields)}</code></td>
                    <td>{x.priority}</td>
                    <td>
                      {fmtZL(ms(x.valid_from))}
                      {x.valid_to ? ` → ${fmtZL(ms(x.valid_to))}` : ' → open'}
                    </td>
                    <td>
                      <Pill tone={st.tone}>{st.text}</Pill>
                      {x.approved_by_name && <div className="k">{x.status === 'REJECTED' ? 'rejected' : 'approved'} by {x.approved_by_name}</div>}
                    </td>
                    <td>
                      <div className="act">
                        {x.kind === 'FILTER' && x.in_force && (
                          <button type="button" className="btn sm" onClick={() => navigate(`/?f=${ruleKey(x.rule_id)}`)}>Apply</button>
                        )}
                        {x.can_approve && (
                          <>
                            <button type="button" className="btn sm primary" onClick={() => run(approve, x, 'Rule approved and in force')}>Approve</button>
                            <button type="button" className="btn sm" onClick={() => run(reject, x, 'Rule rejected')}>Reject</button>
                          </>
                        )}
                        {x.can_retire && (
                          <button type="button" className="btn sm ghost" onClick={() => run(retire, x, 'Rule retired')}>Retire</button>
                        )}
                        {x.status === 'DRAFT' && !x.can_approve && <span className="k">Waiting for an approver</span>}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <NewRuleForm d={d} />
    </div>
  );
}
