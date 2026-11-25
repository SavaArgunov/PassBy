import { AgreementError, DEMO_CONTEXT, agreementView, parseReward, participantRole } from '../agreementModel.js'

export const AGREEMENT_STORAGE_KEY = 'passby:agreement-demo:v1'
const copy = value => JSON.parse(JSON.stringify(value))
const now = () => new Date().toISOString()
const id = () => globalThis.crypto?.randomUUID?.() || `demo-${Date.now()}-${Math.random().toString(36).slice(2)}`

function emptyState() {
  return { schemaVersion: 1, context: copy(DEMO_CONTEXT), deals: [], currentDealId: null, messages: [
    { id: 'm1', authorUserId: DEMO_CONTEXT.deliverer.userId, text: 'Можу забрати посилку завтра о 14:00.', time: '12:41' },
    { id: 'm2', authorUserId: DEMO_CONTEXT.deliveryRequester.userId, text: 'Добре, домовились. За 300 грн?', time: '12:42' },
    { id: 'm3', authorUserId: DEMO_CONTEXT.deliverer.userId, text: 'Так, підходить.', time: '12:43' },
  ] }
}

function draft(context, actorUserId, reward) {
  return { collaborativeDealId: id(), interactionContextId: context.interactionContextId,
    senderUserId: context.sender.userId, receiverUserId: context.receiver.userId,
    delivererUserId: context.deliverer.userId, deliveryRequesterUserId: context.deliveryRequester.userId,
    order: copy(context.order), sender: copy(context.sender), receiver: copy(context.receiver),
    rewardKopecks: parseReward(reward), termsRevision: 1, lastProposedByUserId: actorUserId,
    createdAtUtc: now(), agreedAtUtc: null, handedOverAtUtc: null, cancelledAtUtc: null,
    dealExecutionStatusCode: 'Draft', history: [],
  }
}

// Async adapter boundary. No HTTP routes are implied by these method names.
// Writes re-read persisted state and validate the revision before changing it.
export function createMockAgreementService({ storage = {
  getItem: key => globalThis.localStorage.getItem(key),
  setItem: (key, value) => globalThis.localStorage.setItem(key, value),
}, delay = 180 } = {}) {
  let failNext = false
  function read() {
    let raw
    try { raw = storage.getItem(AGREEMENT_STORAGE_KEY) }
    catch { throw new AgreementError('STORAGE', 'Сховище браузера недоступне. Дозвольте локальне збереження та повторіть спробу.') }
    if (!raw) return emptyState()
    let state
    try { state = JSON.parse(raw) } catch { throw new AgreementError('STORAGE', 'Не вдалося прочитати збережені демодані. Скиньте демосценарій.') }
    if (state.schemaVersion !== 1 || !Array.isArray(state.deals) || !Array.isArray(state.messages) || !state.context?.order) {
      throw new AgreementError('STORAGE', 'Збережені демодані несумісні. Скиньте демосценарій.')
    }
    return state
  }
  function write(state) {
    try { storage.setItem(AGREEMENT_STORAGE_KEY, JSON.stringify(state)) }
    catch { throw new AgreementError('STORAGE', 'Не вдалося зберегти зміни у браузері. Перевірте доступ до сховища.') }
  }
  async function execute(operation, mutate = false) {
    if (delay) await new Promise(resolve => setTimeout(resolve, delay))
    if (failNext) { failNext = false; throw new AgreementError('NETWORK', 'Демонстраційна помилка з’єднання. Спробуйте ще раз.') }
    const state = read()
    operation?.(state)
    if (mutate) write(state)
    return copy(state)
  }
  function current(state, dealId) {
    const deal = state.deals.find(item => item.collaborativeDealId === dealId)
    if (!deal || state.currentDealId !== dealId) throw new AgreementError('CONFLICT', 'Стан угоди змінився. Оновіть дані.')
    return deal
  }
  function authorize(state, actorUserId) {
    if (!participantRole(state.context, actorUserId)) throw new AgreementError('FORBIDDEN', 'Дія доступна лише замовнику та кур’єру цієї взаємодії.')
  }
  function revision(deal, expectedTermsRevision) {
    if (deal.termsRevision !== expectedTermsRevision) throw new AgreementError('CONFLICT', 'Умови вже змінилися. Перегляньте актуальну редакцію та підтвердьте її повторно.')
  }
  function remember(deal, action, actorUserId) {
    const { history, ...snapshot } = deal
    history.push({ action, actorUserId, atUtc: now(), terms: copy(snapshot) })
  }
  const service = {
    getCurrent: () => execute(),
    getDetails: (dealId, actorUserId) => execute(state => { authorize(state, actorUserId); current(state, dealId) }),
    createDraft: ({ actorUserId, reward }) => execute(state => {
      authorize(state, actorUserId)
      if (state.context.interactionStatusCode !== 'Mutual') throw new AgreementError('STATE', 'Спочатку потрібна взаємна згода на спілкування.')
      const previous = state.deals.find(item => item.collaborativeDealId === state.currentDealId)
      if (!agreementView(previous, state.context, actorUserId).canCreate) throw new AgreementError('STATE', 'У цій взаємодії вже є активна угода.')
      const deal = draft(state.context, actorUserId, reward)
      state.deals.push(deal); state.currentDealId = deal.collaborativeDealId
    }, true),
    updateDraft: ({ dealId, actorUserId, expectedTermsRevision, reward }) => execute(state => {
      authorize(state, actorUserId)
      const deal = current(state, dealId)
      revision(deal, expectedTermsRevision)
      if (!agreementView(deal, state.context, actorUserId).canEdit) throw new AgreementError('STATE', 'Редагувати можна лише чернетку угоди.')
      const nextReward = parseReward(reward)
      if (nextReward === deal.rewardKopecks) throw new AgreementError('UNCHANGED', 'Внесіть зміни до винагороди перед збереженням.')
      remember(deal, 'UpdateDraft', actorUserId)
      deal.rewardKopecks = nextReward; deal.termsRevision += 1; deal.lastProposedByUserId = actorUserId
    }, true),
    accept: ({ dealId, actorUserId, expectedTermsRevision }) => execute(state => {
      authorize(state, actorUserId)
      const deal = current(state, dealId)
      revision(deal, expectedTermsRevision)
      if (!agreementView(deal, state.context, actorUserId).canAccept) throw new AgreementError('STATE', 'Власну пропозицію не можна погодити повторно. Очікується згода іншої сторони.')
      remember(deal, 'Accept', actorUserId)
      deal.agreedAtUtc = now(); deal.dealExecutionStatusCode = 'AwaitingHandover'
    }, true),
    cancel: ({ dealId, actorUserId, expectedTermsRevision }) => execute(state => {
      authorize(state, actorUserId)
      const deal = current(state, dealId)
      revision(deal, expectedTermsRevision)
      // Team requirement: also allow AwaitingHandover. SQL currently only allows Draft.
      if (!agreementView(deal, state.context, actorUserId).canCancel) throw new AgreementError('STATE', 'Скасування недоступне: посилку вже передано кур’єру або угода завершена.')
      remember(deal, 'Cancel', actorUserId)
      deal.dealExecutionStatusCode = 'Failed'; deal.cancelledAtUtc = now()
    }, true),
    sendMessage: ({ actorUserId, text }) => execute(state => {
      authorize(state, actorUserId)
      if (!text.trim() || text.trim().length > 2000) throw new AgreementError('MESSAGE', 'Повідомлення має містити від 1 до 2000 символів.')
      state.messages.push({ id: id(), authorUserId: actorUserId, text: text.trim(), time: new Date().toLocaleTimeString('uk-UA', { hour: '2-digit', minute: '2-digit' }) })
    }, true),
    // Explicit demo-only controls. Not an API for real handover or identity changes.
    demo: {
      failNextRequest() { failNext = true },
      reset: async (scenario = 'empty') => {
        const state = emptyState()
        if (scenario !== 'empty') {
          const actor = scenario === 'requester' ? state.context.deliveryRequester.userId : state.context.deliverer.userId
          const deal = draft(state.context, actor, '300')
          if (['agreed', 'handover'].includes(scenario)) { deal.agreedAtUtc = now(); deal.dealExecutionStatusCode = 'AwaitingHandover' }
          if (scenario === 'handover') { deal.handedOverAtUtc = now(); deal.dealExecutionStatusCode = 'InTransit' }
          if (scenario === 'cancelled') { deal.cancelledAtUtc = now(); deal.dealExecutionStatusCode = 'Failed' }
          state.deals.push(deal); state.currentDealId = deal.collaborativeDealId
        }
        failNext = false; write(state); return copy(state)
      },
      handover: ({ dealId, actorUserId }) => execute(state => {
        authorize(state, actorUserId)
        const deal = current(state, dealId)
        if (deal.dealExecutionStatusCode !== 'AwaitingHandover') throw new AgreementError('STATE', 'Спочатку укладіть угоду.')
        remember(deal, 'DemoHandover', actorUserId)
        deal.handedOverAtUtc = now(); deal.dealExecutionStatusCode = 'InTransit'
      }, true),
    },
  }
  return service
}
