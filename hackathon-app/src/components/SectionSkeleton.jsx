// A placeholder that looks like the console (tiles, filter row, flight rows) so a section that is still loading is never an empty screen.
export default function SectionSkeleton({ compact = false, label = 'Loading' }) {
  return (
    <div className="skel-wrap" role="status" aria-label={label}>
      {!compact && (
        <div className="skel-tiles">
          {Array.from({ length: 7 }, (_, i) => <i className="skel" key={i} />)}
        </div>
      )}
      <div className="skel-rows">
        {Array.from({ length: compact ? 3 : 6 }, (_, i) => <i className="skel row" key={i} />)}
      </div>
    </div>
  );
}
