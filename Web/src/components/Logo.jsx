import { BoxIcon } from './Icons.jsx';

export default function Logo({ withText = false }) {
  return (
    <div className="logo">
      <span className="logo-mark">
        <BoxIcon size={20} color="#fff" />
      </span>
      {withText && <span className="logo-text">PassBy</span>}
    </div>
  );
}
