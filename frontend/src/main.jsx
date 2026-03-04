// OTel MUST be imported before anything else so instrumentation is active
// before any fetch or other instrumented APIs are called.
import './tracing.js';

import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
