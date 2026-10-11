// UI metadata and contextual fragments, kept separate from user content.
function refinementProtectedAncestor(element, includeSelf = true) {
  let current = includeSelf ? element : element && element.parentElement;
  while (current) {
    if (['PRE','CODE','SCRIPT','STYLE'].includes(current.tagName)) return true;
    if (current.getAttribute && (
      ['true','plaintext-only',''].includes(current.getAttribute('contenteditable')) ||
      current.getAttribute('role') === 'textbox' ||
      current.getAttribute('data-lexical-editor') === 'true')) return true;
    if (current.classList && ['monaco-editor','user-message','group/user-input-step','thought-content','thinking-content','markdown','prose'].some(c => current.classList.contains(c))) return true;
    current = current.parentElement || (current.getRootNode && current.getRootNode().host);
  }
  return false;
}

function translateSafeAttributes(element, requested) {
  if (!element || element.nodeType !== Node.ELEMENT_NODE || !element.getAttribute) return;
  const isInput = ['INPUT','TEXTAREA'].includes(element.tagName) ||
    ['true','plaintext-only',''].includes(element.getAttribute('contenteditable')) ||
    element.getAttribute('role') === 'textbox' || element.getAttribute('data-lexical-editor') === 'true';
  if (refinementProtectedAncestor(element, !isInput)) return;
  const attributes = requested || ['placeholder','data-placeholder','title','aria-label'];
  for (const attribute of attributes) {
    if (!['placeholder','data-placeholder','title','aria-label'].includes(attribute)) continue;
    const original = element.getAttribute(attribute);
    if (!original || !original.trim()) continue;
    let translated;
    if (isInput) {
      // Only known UI phrases; never translate entered values or editable text.
      const key = original.trim().replace(/\s+/g, ' ');
      const replacement = Object.prototype.hasOwnProperty.call(dictionary,key) ? dictionary[key] : lowerDictionary.get(key.toLowerCase());
      translated = replacement === undefined ? original : original.replace(original.trim(),replacement);
    } else {
      const testId = element.getAttribute('data-testid') || '';
      const href = element.getAttribute('href') || '';
      if ((/^\/c\//.test(href) || /conversation-(?:title|name)|project-name/.test(testId)) && !/^Untitled Conversation$/i.test(original.trim())) continue;
      translated = translateString(original);
    }
    if (translated !== original) element.setAttribute(attribute,translated);
  }
}

function refinementText(node) {
  if (!node || !node.parentElement || !node.nodeValue) return null;
  const element = node.parentElement;
  const text = node.nodeValue;
  const trimmed = text.trim();
  if (element.closest('[data-testid="plan-command-fyi-alert"]')) {
    if (trimmed === 'Type') return text.replace(trimmed,'输入');
    if (/^to have the agent generate a plan\.?$/.test(trimmed)) return '，让智能体生成计划。';
  }
  if (/^to be installed\.?$/.test(trimmed) && /Configure the browser subagent|浏览器子智能体需要先安装/.test(element.textContent || '')) return '。';
  // "Plan" is a subscription heading on the quota page; elsewhere it remains a task plan.
  if (trimmed === 'Plan' && /^H[1-6]$/.test(element.tagName)) {
    let parent = element.parentElement;
    for (let depth = 0; depth < 3 && parent; depth++,parent=parent.parentElement) {
      if (/Google AI (?:Pro|Ultra)|Your [Pp]lan|当前订阅/.test(parent.textContent || '')) return text.replace(trimmed,'订阅方案');
    }
  }
  // Relative ages in the sidebar, never a duration in code or a file name.
  if (element.closest('nav')) {
    const match = trimmed.match(/^(\d+)(mo|d|h|m|s)$/);
    if (match) return text.replace(trimmed,match[1]+({mo:'个月前',d:'天前',h:'小时前',m:'分钟前',s:'秒前'})[match[2]]);
  }
  return null;
}

function refineInlineSpacing(element) {
  if (!element || !element.childNodes) return;
  const plan = element.getAttribute && element.getAttribute('data-testid') === 'plan-command-fyi-alert';
  const browser = Array.from(element.childNodes).some(n => n.nodeType === Node.TEXT_NODE && /Configure the browser subagent|浏览器子智能体需要先安装/.test(n.nodeValue || ''));
  if (!plan && !browser) return;
  for (const node of element.childNodes) {
    if (node.nodeType !== Node.TEXT_NODE || !/^\s+$/.test(node.nodeValue || '')) continue;
    const next = node.nextSibling;
    if (next && next.nodeType === Node.TEXT_NODE && /^(?:to have the agent generate a plan|to be installed|[，。])/.test((next.nodeValue || '').trim())) node.nodeValue = '';
  }
}
