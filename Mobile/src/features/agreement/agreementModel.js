export const DEMO_CONTEXT = {
  interactionContextId: 'demo-interaction-148',
  interactionStatusCode: 'Mutual',
  order: { id: 'PB-1048', from: 'Харків', to: 'Полтава', parcel: 'Документи A4', weight: '0,5 кг' },
  deliverer: { userId: 'demo-deliverer', name: 'ЯроСава Жижа' },
  deliveryRequester: { userId: 'demo-requester', name: 'Олександр Коваленко' },
  sender: { userId: 'demo-sender', name: 'Василій Призначевський' },
  receiver: { userId: 'demo-receiver', name: 'Ігор Петрович' },
}

export class AgreementError extends Error {
  constructor(code, message) { super(message); this.code = code }
}

export function participantRole(context, userId) {
  if (context.deliverer.userId === userId) return 'Deliverer'
  if (context.deliveryRequester.userId === userId) return 'DeliveryRequester'
  return null
}

// Parse money as integer kopecks; never round an imprecise input into a valid price.
export function parseReward(value) {
  const text = String(value ?? '').trim().replace(',', '.')
  if (!/^\d+(?:\.\d{1,2})?$/.test(text)) throw new AgreementError('PRICE', 'Введіть коректну суму, не більше двох знаків після коми.')
  const [whole, fraction = ''] = text.split('.')
  const kopecks = Number(whole) * 100 + Number(fraction.padEnd(2, '0'))
  if (!Number.isSafeInteger(kopecks) || kopecks > 999999999) throw new AgreementError('PRICE', 'Введена сума завелика.')
  if (kopecks < 10000) throw new AgreementError('PRICE', 'Мінімальна винагорода — 100 грн.')
  return kopecks
}

export function financials(rewardKopecks) {
  const commissionKopecks = Math.round(rewardKopecks * 20 / 100)
  return { rewardKopecks, commissionKopecks, totalKopecks: rewardKopecks + commissionKopecks }
}

export function money(kopecks) {
  return new Intl.NumberFormat('uk-UA', { minimumFractionDigits: kopecks % 100 ? 2 : 0, maximumFractionDigits: 2 }).format(kopecks / 100) + ' грн'
}

export function agreementView(deal, context, actorUserId) {
  const participant = !!participantRole(context, actorUserId)
  const draft = deal?.dealExecutionStatusCode === 'Draft'
  const isAgreed = !!deal?.agreedAtUtc
  const cancelled = deal?.dealExecutionStatusCode === 'Failed'
  const handedOver = !!deal?.handedOverAtUtc || ['InTransit', 'AwaitingPayout', 'Fulfilled'].includes(deal?.dealExecutionStatusCode)
  return {
    draft, isAgreed, cancelled, handedOver,
    delivererAccepted: !!deal && (isAgreed || deal.lastProposedByUserId === context.deliverer.userId),
    deliveryRequesterAccepted: !!deal && (isAgreed || deal.lastProposedByUserId === context.deliveryRequester.userId),
    canCreate: participant && (!deal || cancelled),
    canEdit: participant && draft,
    canAccept: participant && draft && deal.lastProposedByUserId !== actorUserId,
    canCancel: participant && !!deal && !handedOver && ['Draft', 'AwaitingHandover'].includes(deal.dealExecutionStatusCode),
  }
}
