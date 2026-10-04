import { createRoot } from 'react-dom/client';
import '@fontsource-variable/inter';
import './styles.css';
import App from './App.jsx';

createRoot(document.getElementById('root')).render(<App />);

if (import.meta.env.VITE_TEST_CONTROL === '1') {
  import('./testControl.js').then((m) => m.startTestControl({
    startSync: () => window.__fieldbook.startSync(),
    refresh: () => window.__fieldbook.refresh(),
    go: (name) => window.__fieldbook.go(name),
    state: () => window.__fieldbook.state(),
  }));
}
