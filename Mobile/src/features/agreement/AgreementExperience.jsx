import { useCallback, useEffect, useRef, useState } from 'react'
import { agreementView, financials, money, parseReward, participantRole } from './agreementModel.js'
import { createMockAgreementService } from './services/mockAgreementService.js'
import './agreement.css'

const roleLabel = role => role === 'Deliverer' ? 'Кур’єр' : 'Замовник'

function Icon({ name, ...props }) {
  const paths = {
    person: <><circle cx="12" cy="7" r="3" /><path d="M5 21v-3a7 7 0 0 1 14 0v3" /></>,
    back: <path d="m14 6-6 6 6 6M8 12h13" />,
    check: <path d="m5 12 4 4L19 6" />,
    clock: <><circle cx="12" cy="12" r="9" /><path d="M12 6v6l4 3" /></>,
    edit: <><path d="M11 4H4v16h14v-7M10 14l1-5 8-7 3 3-8 8-4 1Z" /></>,
    document: <><path d="M6 2h9l5 5v15H6V2Zm9 0v6h5M9 12h8M9 16h8" /></>,
    cancel: <><circle cx="12" cy="12" r="10" /><path d="M9 9l6 6M15 9l-6 6" /></>,
    lock: <><rect x="6" y="10" width="12" height="11" rx="1" /><path d="M8 10V6a4 4 0 0 1 8 0v4" /></>,
    send: <path d="M12 21V3M4 11l8-8 8 8" />,
    plus: <path d="M12 4v16M4 12h16" />,
  }
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>{paths[name]}</svg>
}

function Consent({ label, accepted, cancelled }) {
  return <div className={`ag-consent ${accepted && !cancelled ? 'is-accepted' : ''}`}>
    <b>{label}</b><span><Icon name={accepted ? 'check' : 'clock'} />{accepted ? 'Погоджено' : 'Очікується згода'}</span>
  </div>
}

function Consents({ view, compact = false }) {
  return <div className={`agreement-roles ag-consents ${compact ? 'ag-consents-compact' : ''}`} aria-label="Погодження учасників">
    <Consent label="Кур’єр" accepted={view.delivererAccepted} cancelled={view.cancelled} />
    <Consent label="Замовник" accepted={view.deliveryRequesterAccepted} cancelled={view.cancelled} />
  </div>
}

function Finances({ rewardKopecks, isRequester, detailed = false, showReward = true }) {
  const amounts = financials(rewardKopecks)
  return <div className={`ag-finances ${detailed ? 'ag-finances-detailed' : ''}`}>
    {showReward && <div><span>Винагорода{detailed ? ' без комісії' : ' кур’єру'}</span><b>{money(rewardKopecks)}</b></div>}
    {isRequester && <><div><span>Комісія PassBy · 20%</span><b>{money(amounts.commissionKopecks)}</b></div><div className="ag-total"><span>Разом до сплати</span><b>{money(amounts.totalKopecks)}</b></div></>}
  </div>
}

function Modal({ title, children, onClose, busy, className = '' }) {
  const ref = useRef(null)
  const closeRef = useRef(onClose)
  closeRef.current = onClose
  useEffect(() => {
    const node = ref.current
    const previous = document.activeElement
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    node.showModal()
    return () => { node.close(); document.body.style.overflow = previousOverflow; previous?.focus?.({ preventScroll: true }) }
  }, [])
  return <dialog ref={ref} className={`native-dialog ag-modal ${className}`} aria-labelledby="agreement-dialog-title" aria-busy={busy}
    onCancel={event => { event.preventDefault(); if (!busy) closeRef.current() }}>
    <h2 id="agreement-dialog-title">{title}</h2>
    <button className="ag-modal-close" aria-label="Закрити вікно" disabled={busy} onClick={onClose}>×</button>
    {children}
  </dialog>
}

function DraftEditor({ deal, context, isRequester, ui, busy, error, onSave, onClose }) {
  const { Button, Field } = ui
  const [reward, setReward] = useState(deal ? String(deal.rewardKopecks / 100) : '300')
  const [validation, setValidation] = useState('')
  let validPrice = null
  try { validPrice = parseReward(reward) } catch { /* Validation is shown on submit. */ }
  return <Modal title={<>Створення / редагування<br />чернетки</>} onClose={onClose} busy={busy} className="ag-editor">
    <p className="ag-help">Маршрут узято із замовлення.<br />Змінити його в чернетці неможливо.</p>
    <form onSubmit={event => { event.preventDefault(); try { parseReward(reward); setValidation(''); onSave(reward) } catch (reason) { setValidation(reason.message) } }} noValidate>
      <fieldset disabled={busy}>
        <label className="ag-locked"><span>Звідки</span><span><input aria-label="Звідки" readOnly value={context.order.from} /><Icon name="lock" /></span></label>
        <label className="ag-locked"><span>Куди</span><span><input aria-label="Куди" readOnly value={context.order.to} /><Icon name="lock" /></span></label>
        <div className="ag-reward-field"><Field label="Винагорода (грн)" value={reward} inputMode="decimal" maxLength={12} aria-invalid={!!validation} aria-describedby="reward-error" onChange={event => { setReward(event.target.value); setValidation('') }} /><span>грн</span></div>
        <div className="ag-assigned"><div><span>Призначений відправник</span><b>{context.sender.name}</b></div><div><span>Призначений отримувач</span><b>{context.receiver.name}</b></div></div>
        {validPrice !== null && isRequester && <Finances rewardKopecks={validPrice} isRequester />}
        {(validation || error) && <p className="ag-error" id="reward-error" role="alert">{validation || error}</p>}
        <div className="dialog-actions ag-editor-actions"><Button kind="secondary" type="button" onClick={onClose}>Скасувати</Button><Button type="submit">{busy ? 'Збереження…' : 'Зберегти чернетку'}</Button></div>
      </fieldset>
    </form>
  </Modal>
}

function AgreementApproval({ deal, context, actorUserId, ui, busy, error, onClose, onEdit, onAccept, onCancel }) {
  const { Button } = ui
  const view = agreementView(deal, context, actorUserId)
  const isRequester = participantRole(context, actorUserId) === 'DeliveryRequester'
  const proposer = deal.lastProposedByUserId === context.deliverer.userId ? 'Кур’єр' : 'Замовник'
  const notice = view.cancelled ? 'Ця угода більше не активна. Ви можете продовжити спілкування в чаті.'
    : view.isAgreed ? 'Обидві сторони погодили умови. Угоду укладено. Умови зафіксовано.'
      : `${proposer} ${deal.termsRevision === 1 ? 'створив чернетку' : `запропонував редакцію ${deal.termsRevision}`}. ${view.canAccept ? 'Перевірте умови перед погодженням.' : 'Вашу згоду зафіксовано. Очікується згода іншої сторони.'}`
  return <Modal title="Погодження угоди" onClose={onClose} busy={busy} className="ag-approval">
    <section className="agreement-data ag-terms" aria-label="Умови угоди">
      <div className="ag-route"><div><small>Доставка з</small><b>{deal.order.from}</b></div><div><small>Доставка у</small><b>{deal.order.to}</b></div></div>
      <dl>
        <div><dt>Кур’єр</dt><dd>{context.deliverer.name}</dd></div>
        <div><dt>Призначений відправник</dt><dd>{deal.sender.name}</dd></div>
        <div><dt>Призначений отримувач</dt><dd>{deal.receiver.name}</dd></div>
        <div><dt>Фінальна ціна</dt><dd>{money(deal.rewardKopecks)}</dd></div>
        <div><dt>Остання пропозиція</dt><dd>{proposer}</dd></div>
        <div><dt>Статус</dt><dd className={view.isAgreed ? 'ag-green' : 'ag-blue'}>{view.cancelled ? 'Скасовано' : view.isAgreed ? 'Угоду укладено' : 'Чернетка'}</dd></div>
      </dl>
    </section>
    <p className="ag-revision">Замовлення {deal.order.id} · Редакція {deal.termsRevision}</p>
    <Consents view={view} />
    {isRequester && <Finances rewardKopecks={deal.rewardKopecks} isRequester />}
    <p className={`ag-notice ${view.isAgreed && !view.cancelled ? 'ag-notice-success' : ''}`} role="status">{notice}</p>
    {error && <p className="ag-error" role="alert">{error}</p>}
    <div className="ag-approval-actions">
      {view.draft ? <><Button kind="secondary" disabled={busy || !view.canEdit} onClick={onEdit}>Редагувати</Button><Button disabled={busy || !view.canAccept} onClick={onAccept}>{busy ? 'Погодження…' : 'Погодити'}</Button></> : <Button onClick={onClose} disabled={busy}>Повернутися до чату</Button>}
    </div>
    {view.canCancel && <Button kind="danger" className="ag-cancel" disabled={busy} onClick={onCancel}>Скасувати угоду</Button>}
  </Modal>
}

function DealCard({ deal, context, actorUserId, ui, onReview, onEdit, onCancel, onDetails, busy }) {
  const { Button } = ui
  const view = agreementView(deal, context, actorUserId)
  return <section className={`deal-card ag-deal-card ${view.cancelled ? 'ag-cancelled' : ''}`} aria-label="Угода в чаті">
    <div className="ag-card-heading"><span className="ag-card-icon"><Icon name={view.cancelled ? 'cancel' : view.isAgreed ? 'check' : 'edit'} /></span><h2>{view.cancelled ? 'Угоду скасовано' : view.isAgreed ? 'Угоду укладено' : 'Чернетка угоди'}</h2><span className="ag-badge">{view.cancelled ? 'Скасовано' : view.isAgreed ? 'Укладено' : 'Чернетка'}</span></div>
    <div className="ag-card-body"><b>Винагорода: {money(deal.rewardKopecks)}</b><p>Місце отримання: {deal.order.from}</p><p>Місце доставки: {deal.order.to}</p>
      <div className="ag-assigned"><div><span>Призначений відправник</span><b>{deal.sender.name}</b></div><div><span>Призначений отримувач</span><b>{deal.receiver.name}</b></div></div>
      {participantRole(context, actorUserId) === 'DeliveryRequester' && <Finances rewardKopecks={deal.rewardKopecks} isRequester showReward={false} />}
      {view.cancelled ? <p className="ag-cancelled-note">Ця угода більше не активна.<br />Ви можете продовжити спілкування в чаті.</p> : <>
        <Consents view={view} compact />
        <p className="ag-revision">Редакція {deal.termsRevision} · {view.isAgreed ? 'Умови зафіксовано' : 'Очікується згода іншої сторони'}</p>
        <Button className="ag-review" onClick={view.isAgreed ? onDetails : onReview}>{view.isAgreed ? 'Деталі угоди' : 'Переглянути'}</Button>
        {view.draft && <div className="ag-card-links"><button disabled={busy} onClick={onEdit}>Редагувати</button><button disabled={busy || !view.canAccept} onClick={onReview}>Погодити</button><button disabled={busy} className="ag-red" onClick={onCancel}>Скасувати угоду</button></div>}
      </>}
    </div>
  </section>
}

function Chat({ state, deal, actorUserId, ui, busy, onBack, onMessage, onEdit, onReview, onCancel, onDetails, onToast }) {
  const { Brand } = ui
  const [message, setMessage] = useState('')
  const peer = actorUserId === state.context.deliverer.userId ? state.context.deliveryRequester : state.context.deliverer
  const peerRole = participantRole(state.context, peer.userId)
  const view = agreementView(deal, state.context, actorUserId)
  async function send(event) { event.preventDefault(); if (await onMessage(message)) setMessage('') }
  return <main className="screen chat-screen ag-screen ag-chat">
    <header className="ag-chat-header"><Brand /><div className="ag-peer"><button className="ag-icon-button ag-back" aria-label="Назад" onClick={onBack}><Icon name="back" /></button><span className="ag-avatar"><Icon name="person" /></span><div><b>{peer.name}</b><small>{roleLabel(peerRole)} <span className="ag-mutual">· Mutual · Взаємодія</span></small></div><button className="ag-icon-button" aria-label="Інформація про взаємодію" onClick={() => onToast('Mutual · Обидва учасники погодилися на спілкування.')}>•••</button></div></header>
    <section className="ag-conversation" aria-label="Історія чату"><p className="ag-today">Сьогодні</p>
      <div className="messages ag-messages">{state.messages.map(item => <article key={item.id} className={`message ag-message ${item.authorUserId === actorUserId ? 'out' : ''}`}><p>{item.text}</p><small>{item.time}</small></article>)}</div>
      {deal ? <DealCard {...{ deal, actorUserId, ui, busy, onEdit, onReview, onCancel, onDetails }} context={state.context} /> : <section className="ag-empty"><Icon name="document" /><h2>Узгодьте умови доставки</h2><p>У цій взаємодії ще немає угоди. Створіть чернетку після обговорення умов.</p><ui.Button onClick={onEdit}>Створити чернетку</ui.Button></section>}
      {view.cancelled && <button className="ag-new-draft" disabled={busy} onClick={onEdit}>Створити нову чернетку</button>}
    </section>
    <footer className="ag-chat-footer"><div className="ag-document-action"><button className="ag-icon-button" aria-label={view.canCreate ? 'Створити чернетку' : 'Переглянути угоду'} disabled={busy} onClick={view.canCreate ? onEdit : view.isAgreed ? onDetails : onReview}><Icon name="document" /></button></div>
      <form className="chat-compose ag-compose" onSubmit={send}><button type="button" className="ag-icon-button" aria-label="Вкладення" onClick={() => onToast('Вкладення будуть доступні в модулі чату.')}><Icon name="plus" /></button><input aria-label="Повідомлення" placeholder="Повідомлення…" maxLength={2000} value={message} onChange={event => setMessage(event.target.value)} /><button className="ag-send" aria-label="Надіслати повідомлення" disabled={busy || !message.trim()}><Icon name="send" /></button></form><span className="ag-gesture" />
    </footer>
  </main>
}

function DetailRow({ label, children }) { return <div className="ag-detail-row"><small>{label}</small><b>{children}</b></div> }

function Details({ deal, context, actorUserId, ui, onChat, onOrder, onCancel, busy, onToast }) {
  const { Button, Footer } = ui
  const view = agreementView(deal, context, actorUserId)
  const delivered = ['AwaitingPayout', 'Fulfilled'].includes(deal.dealExecutionStatusCode)
  const status = view.cancelled ? 'Угоду скасовано' : delivered ? 'Передавання отримувачу підтверджено' : view.handedOver ? 'Посилка в дорозі' : 'Очікується передавання посилки'
  return <main className="screen ag-screen ag-details"><header className="ag-details-header"><b className="ag-wordmark">PassBy</b><button onClick={onOrder}>‹ Мої замовлення</button><h1>Деталі угоди</h1></header>
    <section className="ag-panel ag-state-panel"><span className={`ag-badge ${view.cancelled ? 'ag-badge-red' : 'ag-badge-green'}`}>● {view.cancelled ? 'Скасована угода' : deal.dealExecutionStatusCode === 'Fulfilled' ? 'Виконана угода' : 'Активна угода'}</span><h2>{deal.order.from} → {deal.order.to}</h2><p>{status}</p></section>
    <section className="ag-panel ag-execution"><h2>Виконання угоди</h2><ol>
      <li><span className={view.isAgreed ? 'done' : ''}>{view.isAgreed ? <Icon name="check" /> : '1'}</span><div><b>Угоду укладено</b><small>{view.isAgreed ? 'Обидві сторони погодили умови' : 'Умови не погоджено'}</small></div></li>
      <li><span className={view.handedOver ? 'done' : !view.cancelled ? 'current' : ''}>{view.handedOver ? <Icon name="check" /> : '2'}</span><div><b>Передавання посилки</b><small>{view.handedOver ? 'Передавання кур’єру підтверджено' : view.cancelled ? 'Угоду скасовано до передавання' : 'Очікується підтвердження'}</small></div></li>
      <li><span className={delivered ? 'done' : ''}>{delivered ? <Icon name="check" /> : '3'}</span><div><b>Доставлення посилки</b><small>{delivered ? 'Отримання посилки підтверджено' : view.handedOver ? 'Доставка виконується' : 'Після передавання кур’єру'}</small></div></li>
    </ol>{!view.cancelled && <div className="ag-stage-note"><b>{view.handedOver ? delivered ? 'Отримання підтверджено' : 'Посилка в дорозі' : 'Передайте посилку кур’єру'}</b><p>{view.handedOver ? 'Відображено відомості поточного стану угоди.' : 'Підтвердження виконується під час зустрічі.'}</p></div>}</section>
    <section className="ag-panel ag-agreed-terms"><h2>Погоджені умови</h2><DetailRow label="Місце отримання">{deal.order.from}</DetailRow><DetailRow label="Місце доставки">{deal.order.to}</DetailRow><DetailRow label="Посилка"><button className="ag-parcel-link" onClick={() => onToast(`${deal.order.parcel} · ${deal.order.weight}`)}>{deal.order.parcel}<span>›</span></button></DetailRow><Finances rewardKopecks={deal.rewardKopecks} isRequester={participantRole(context, actorUserId) === 'DeliveryRequester'} detailed /><DetailRow label="Призначений відправник">{deal.sender.name}</DetailRow><DetailRow label="Призначений отримувач">{deal.receiver.name}</DetailRow><p className="ag-revision">Замовлення {deal.order.id} · Редакція {deal.termsRevision}</p></section>
    <section className="ag-panel ag-participants"><h2>Учасники угоди</h2>{[context.deliverer, context.deliveryRequester].map(person => <div className="ag-participant" key={person.userId}><span className="ag-avatar">{person.name.slice(0, 1)}</span><div><b>{roleLabel(participantRole(context, person.userId))}</b><small>{person.name}</small></div></div>)}</section>
    <div className="ag-details-actions"><Button onClick={onChat}>Перейти до чату</Button><Button kind="secondary" onClick={onOrder}>До мого замовлення</Button>{view.canCancel && <Button kind="danger" disabled={busy} onClick={onCancel}>Скасувати угоду</Button>}</div><Footer />
  </main>
}

function DemoTools({ state, actorUserId, onActor, onReset, onHandover, onError, onReload, busy, ui }) {
  const deal = state?.deals.find(item => item.collaborativeDealId === state.currentDealId)
  return <details className="ag-demo-tools"><summary>Демо · угода</summary><div><b>Демонстраційний режим</b><p>Локальні дані. Дії не підтверджують реальну доставку чи оплату.</p><fieldset disabled={busy}>
    {state && <label>Поточний учасник<select aria-label="Поточний учасник" value={actorUserId} onChange={event => onActor(event.target.value)}><option value={state.context.deliveryRequester.userId}>Замовник</option><option value={state.context.deliverer.userId}>Кур’єр</option></select></label>}
    <label>Почати сценарій<select aria-label="Почати сценарій" value="" onChange={event => onReset(event.target.value)}><option value="" disabled>Оберіть сценарій…</option><option value="empty">Порожній чат</option><option value="courier">Чернетка кур’єра</option><option value="requester">Чернетка замовника</option><option value="agreed">Укладена угода до передачі</option><option value="handover">Посилку передано кур’єру</option><option value="cancelled">Угоду скасовано</option></select></label>
    <ui.Button kind="secondary" disabled={deal?.dealExecutionStatusCode !== 'AwaitingHandover'} onClick={onHandover}>Імітувати передавання</ui.Button><button onClick={onError}>Помилка наступного запиту</button><button onClick={onReload}>Оновити дані</button>
  </fieldset></div></details>
}

export default function AgreementExperience({ screen, navigate, onExit, ui, toast }) {
  const [service] = useState(() => createMockAgreementService())
  const [state, setState] = useState(null)
  const [actorUserId, setActorUserId] = useState('demo-requester')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [modal, setModal] = useState(null)
  const actionLock = useRef(false)
  const load = useCallback(async () => {
    setLoading(true); setError('')
    try { setState(await service.getCurrent()) } catch (reason) { setError(reason.message) }
    finally { setLoading(false) }
  }, [service])
  useEffect(() => { load() }, [load])
  useEffect(() => { window.scrollTo(0, 0) }, [screen])
  useEffect(() => {
    const onStorage = event => { if (!event.key || event.key === 'passby:agreement-demo:v1') load() }
    window.addEventListener('storage', onStorage)
    return () => window.removeEventListener('storage', onStorage)
  }, [load])
  const deal = state?.deals.find(item => item.collaborativeDealId === state.currentDealId)
  async function perform(action, success, close = true) {
    if (actionLock.current) return false
    actionLock.current = true; setBusy(true); setError('')
    try {
      const next = await action()
      setState(next)
      if (close) setModal(null)
      else if (modal?.type === 'review') setModal({ type: 'review', deal: structuredClone(next.deals.find(item => item.collaborativeDealId === next.currentDealId)) })
      if (success) toast(success)
      return true
    }
    catch (reason) {
      setError(reason.message)
      if (reason.code === 'CONFLICT') {
        setModal(null)
        try { setState(await service.getCurrent()) } catch { /* Keep conflict visible; retry is available. */ }
      }
      return false
    } finally { actionLock.current = false; setBusy(false) }
  }
  function openModal(type) { setError(''); setModal({ type, deal: deal && !(type === 'edit' && deal.dealExecutionStatusCode === 'Failed') ? structuredClone(deal) : null }) }
  function args(snapshot = deal) { return { dealId: snapshot?.collaborativeDealId, actorUserId, expectedTermsRevision: snapshot?.termsRevision } }
  async function openDetails() {
    if (await perform(() => service.getDetails(deal.collaborativeDealId, actorUserId))) navigate('agreement-details')
  }
  const tools = <DemoTools {...{ state, actorUserId, busy, ui }} onActor={value => { setActorUserId(value); setModal(null); setError('') }}
    onReset={scenario => perform(() => service.demo.reset(scenario), 'Демосценарій завантажено.').then(ok => { if (ok) navigate('agreement-chat') })}
    onHandover={() => perform(() => service.demo.handover(args()), 'Демо: передавання посилки підтверджено.')}
    onError={() => { service.demo.failNextRequest(); toast('Наступний запит завершиться демонстраційною помилкою.') }} onReload={load} />
  if (loading || !state) return <div className="ag-feature"><main className="screen ag-screen ag-loading"><ui.Brand /><p role="status">{loading ? 'Завантаження угоди…' : error}</p>{!loading && <ui.Button onClick={load}>Спробувати ще раз</ui.Button>}<ui.Button kind="secondary" onClick={onExit}>До PassBy</ui.Button></main>{tools}</div>
  const view = agreementView(deal, state.context, actorUserId)
  return <div className="ag-feature" aria-busy={busy}>
    {error && !modal && <div className="ag-error-banner" role="alert">{error}<button disabled={busy} onClick={load}>Оновити</button></div>}
    {screen === 'agreement-details' && deal && !view.draft ? <Details {...{ deal, actorUserId, ui, busy }} context={state.context} onChat={() => navigate('agreement-chat')} onOrder={() => navigate('agreement-order')} onCancel={() => openModal('cancel')} onToast={toast} />
      : screen === 'agreement-order' ? <main className="screen ag-screen ag-order"><ui.PageHeader title="Моє замовлення" back={() => navigate('agreement-chat')} /><h1>{state.context.order.from} → {state.context.order.to}</h1><section className="ag-panel"><h2>Замовлення {state.context.order.id}</h2><DetailRow label="Посилка">{state.context.order.parcel} · {state.context.order.weight}</DetailRow><DetailRow label="Призначений відправник">{state.context.sender.name}</DetailRow><DetailRow label="Призначений отримувач">{state.context.receiver.name}</DetailRow></section><p className="ag-help">Демонстраційний контекст замовлення. Повний модуль замовлень розробляється окремо.</p>{deal && !view.draft && <ui.Button onClick={openDetails}>Деталі угоди</ui.Button>}<ui.Button kind="secondary" onClick={() => navigate('agreement-chat')}>Перейти до чату</ui.Button><ui.Button kind="secondary" onClick={onExit}>До PassBy</ui.Button></main>
        : <Chat {...{ state, deal, actorUserId, ui, busy }} onBack={onExit} onMessage={text => perform(() => service.sendMessage({ actorUserId, text }), '', false)} onEdit={() => openModal('edit')} onReview={() => openModal('review')} onCancel={() => openModal('cancel')} onDetails={openDetails} onToast={toast} />}
    {modal?.type === 'edit' && <DraftEditor deal={modal.deal} context={state.context} isRequester={participantRole(state.context, actorUserId) === 'DeliveryRequester'} {...{ ui, busy, error }} onClose={() => setModal(null)} onSave={reward => perform(() => modal.deal ? service.updateDraft({ ...args(modal.deal), reward }) : service.createDraft({ actorUserId, reward }), 'Чернетку збережено. Вашу згоду зафіксовано.')} />}
    {modal?.type === 'review' && modal.deal && <AgreementApproval deal={modal.deal} context={state.context} {...{ actorUserId, ui, busy, error }} onClose={() => setModal(null)} onEdit={() => openModal('edit')} onAccept={() => perform(() => service.accept(args(modal.deal)), 'Угоду укладено. Очікується передавання посилки.', false)} onCancel={() => openModal('cancel')} />}
    {modal?.type === 'cancel' && <Modal title="Скасувати угоду?" onClose={() => setModal(null)} busy={busy} className="ag-confirm-cancel"><p>Угода більше не буде активною. Історія умов і переписка збережуться, а чат залишиться доступним.</p>{error && <p className="ag-error" role="alert">{error}</p>}<div className="dialog-actions"><ui.Button kind="secondary" disabled={busy} onClick={() => setModal(null)}>Залишити угоду</ui.Button><ui.Button kind="danger" disabled={busy} onClick={() => perform(() => service.cancel(args(modal.deal)), 'Угоду скасовано. Чат залишається доступним.').then(ok => { if (ok) navigate('agreement-chat') })}>{busy ? 'Скасування…' : 'Скасувати угоду'}</ui.Button></div></Modal>}
    {tools}
  </div>
}
