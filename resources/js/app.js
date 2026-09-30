import './bootstrap';
import { greeting } from './greeting';

const el = document.getElementById('greeting');
if (el) el.textContent = `${greeting()}!`;
