import test from 'node:test'
import assert from 'node:assert/strict'
import { DEMO_CONTEXT as context, agreementView, financials, money, parseReward } from './agreementModel.js'
import { AGREEMENT_STORAGE_KEY, createMockAgreementService } from './services/mockAgreementService.js'

const courier = context.deliverer.userId
const requester = context.deliveryRequester.userId
function setup() {
  const data = new Map()
  const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value) }
  const service = createMockAgreementService({ storage, delay: 0 })
  return { service, storage, data }
}
const current = state => state.deals.find(item => item.collaborativeDealId === state.currentDealId)
const args = (deal, actorUserId) => ({ dealId: deal.collaborativeDealId, expectedTermsRevision: deal.termsRevision, actorUserId })

for (const author of [courier, requester]) {
  test(`author ${author}: automatic consent, no self acceptance, other participant concludes`, async () => {
    const { service } = setup()
    const deal = current(await service.createDraft({ actorUserId: author, reward: '300' }))
    const other = author === courier ? requester : courier
    const view = agreementView(deal, context, author)
    assert.equal(view.canAccept, false)
    assert.equal(view.delivererAccepted, author === courier)
    assert.equal(view.deliveryRequesterAccepted, author === requester)
    await assert.rejects(service.accept(args(deal, author)), { code: 'STATE' })
    const accepted = current(await service.accept(args(deal, other)))
    assert.equal(accepted.dealExecutionStatusCode, 'AwaitingHandover')
    assert.ok(accepted.agreedAtUtc)
    assert.equal(accepted.handedOverAtUtc, null)
    assert.equal(agreementView(accepted, context, other).delivererAccepted, true)
    assert.equal(agreementView(accepted, context, other).deliveryRequesterAccepted, true)
    await assert.rejects(service.updateDraft({ ...args(accepted, author), reward: '350' }), { code: 'STATE' })
    await assert.rejects(service.accept(args(accepted, other)), { code: 'STATE' })
  })
}

test('new proposal changes consent; stale revisions cannot update, accept or cancel', async () => {
  const { service } = setup()
  const initial = current(await service.createDraft({ actorUserId: courier, reward: '300' }))
  const updated = current(await service.updateDraft({ ...args(initial, requester), reward: '350,15' }))
  assert.equal(updated.termsRevision, 2)
  assert.equal(updated.rewardKopecks, 35015)
  assert.equal(agreementView(updated, context, courier).delivererAccepted, false)
  assert.equal(agreementView(updated, context, courier).deliveryRequesterAccepted, true)
  assert.equal(updated.history[0].terms.rewardKopecks, 30000)
  await assert.rejects(service.accept(args(initial, courier)), { code: 'CONFLICT' })
  await assert.rejects(service.updateDraft({ ...args(initial, courier), reward: '400' }), { code: 'CONFLICT' })
  await assert.rejects(service.cancel(args(initial, courier)), { code: 'CONFLICT' })
  await assert.rejects(service.updateDraft({ ...args(updated, courier), reward: '350.15' }), { code: 'UNCHANGED' })
  assert.ok(current(await service.accept(args(updated, courier))).agreedAtUtc)
})

test('cancel draft and agreed deal before handover; keep chat and deal history', async () => {
  for (const conclude of [false, true]) {
    const { service } = setup()
    let deal = current(await service.createDraft({ actorUserId: courier, reward: '300' }))
    if (conclude) deal = current(await service.accept(args(deal, requester)))
    const state = await service.cancel(args(deal, requester))
    assert.equal(current(state).dealExecutionStatusCode, 'Failed')
    assert.equal(current(state).termsRevision, 1)
    assert.equal(state.messages.length, 3)
    const chatted = await service.sendMessage({ actorUserId: courier, text: 'Можемо домовитись пізніше.' })
    assert.equal(chatted.messages.length, 4)
    const recreated = await service.createDraft({ actorUserId: requester, reward: '320' })
    assert.equal(recreated.deals.length, 2)
    assert.equal(recreated.deals[0].dealExecutionStatusCode, 'Failed')
  }
})

test('no cancellation after confirmed handover, for either participant', async () => {
  const { service } = setup()
  let deal = current(await service.createDraft({ actorUserId: requester, reward: '300' }))
  deal = current(await service.accept(args(deal, courier)))
  deal = current(await service.demo.handover(args(deal, requester)))
  assert.equal(deal.dealExecutionStatusCode, 'InTransit')
  for (const actor of [courier, requester]) {
    assert.equal(agreementView(deal, context, actor).canCancel, false)
    await assert.rejects(service.cancel(args(deal, actor)), { code: 'STATE' })
  }
})

test('assigned sender and receiver are distinct from approval participants', async () => {
  const { service } = setup()
  const deal = current(await service.createDraft({ actorUserId: requester, reward: '100' }))
  assert.deepEqual(deal.sender, context.sender)
  assert.deepEqual(deal.receiver, context.receiver)
  for (const actor of [context.sender.userId, context.receiver.userId, 'stranger']) {
    assert.equal(agreementView(deal, context, actor).canAccept, false)
    await assert.rejects(service.accept(args(deal, actor)), { code: 'FORBIDDEN' })
    await assert.rejects(service.getDetails(deal.collaborativeDealId, actor), { code: 'FORBIDDEN' })
  }
})

test('money input and 20% commission use kopecks with consistent rounding', () => {
  for (const value of ['', ' ', '-100', '99.99', 'abc', '100.123', 'Infinity', '1e3']) assert.throws(() => parseReward(value))
  assert.equal(parseReward('100'), 10000)
  assert.equal(parseReward('300,15'), 30015)
  assert.deepEqual(financials(30000), { rewardKopecks: 30000, commissionKopecks: 6000, totalKopecks: 36000 })
  assert.deepEqual(financials(10003), { rewardKopecks: 10003, commissionKopecks: 2001, totalKopecks: 12004 })
  assert.equal(money(45030), '450,30 грн')
  assert.equal(money(30000), '300 грн')
})

test('failed requests do not create or confirm a deal; storage keys are isolated', async () => {
  const { service, data } = setup()
  service.demo.failNextRequest()
  await assert.rejects(service.createDraft({ actorUserId: courier, reward: '300' }), { code: 'NETWORK' })
  assert.equal((await service.getCurrent()).deals.length, 0)
  const deal = current(await service.createDraft({ actorUserId: courier, reward: '300' }))
  service.demo.failNextRequest()
  await assert.rejects(service.accept(args(deal, requester)), { code: 'NETWORK' })
  assert.equal(current(await service.getCurrent()).agreedAtUtc, null)
  assert.deepEqual([...data.keys()], [AGREEMENT_STORAGE_KEY])
})

test('two clients share persisted revisions; concurrent accepts only conclude once', async () => {
  const { service, storage } = setup()
  const otherClient = createMockAgreementService({ storage, delay: 0 })
  const deal = current(await service.createDraft({ actorUserId: requester, reward: '300' }))
  const results = await Promise.allSettled([service.accept(args(deal, courier)), otherClient.accept(args(deal, courier))])
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1)
  assert.equal(current(await otherClient.getCurrent()).history.filter(item => item.action === 'Accept').length, 1)
})

test('storage errors are explicit and can be recovered through demo reset', async () => {
  const { service, storage } = setup()
  storage.setItem(AGREEMENT_STORAGE_KEY, 'broken')
  await assert.rejects(service.getCurrent(), { code: 'STORAGE' })
  assert.equal((await service.demo.reset()).deals.length, 0)
  const unwritable = createMockAgreementService({ storage: { getItem: () => null, setItem() { throw new Error('QuotaExceededError') } }, delay: 0 })
  await assert.rejects(unwritable.createDraft({ actorUserId: courier, reward: '300' }), { code: 'STORAGE' })
  const unreadable = createMockAgreementService({ storage: { getItem() { throw new Error('SecurityError') } }, delay: 0 })
  await assert.rejects(unreadable.getCurrent(), { code: 'STORAGE' })
})
