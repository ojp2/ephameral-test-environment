'use strict';

const express = require('express');
const mysql   = require('mysql2/promise');
const axios   = require('axios');

const app  = express();
app.use(express.json());

const PORT    = process.env.PORT    || 8080;
const GDS_URL = process.env.GDS_URL || 'http://localhost:8081'; // game data
const ESB_URL = process.env.ESB_URL || 'http://localhost:8082'; // account + purchase

// ─── DB pool ──────────────────────────────────────────────────────────────────
const db = mysql.createPool({
  host:             process.env.DB_HOST || 'localhost',
  port:             parseInt(process.env.DB_PORT || '3306'),
  database:         process.env.DB_NAME || 'wagerdb',
  user:             process.env.DB_USER || 'wager',
  password:         process.env.DB_PASS || 'wagerpass',
  waitForConnections: true,
  connectionLimit:  10,
});

// ─── Helpers ──────────────────────────────────────────────────────────────────
async function logTransaction(txnId, gameCode, playerId, amount, status) {
  const id = txnId || `LOCAL-${Date.now()}`;
  try {
    await db.query(
      `INSERT INTO wager_transactions
         (transaction_id, game_code, player_id, wager_amount, status, created_at)
       VALUES (?, ?, ?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE status = VALUES(status)`,
      [id, gameCode, playerId, amount, status]
    );
  } catch (err) {
    console.error('[db] Failed to log transaction:', err.message);
  }
  return id;
}

function upstreamError(res, status, body) {
  return res.status(status).json(body);
}

// ─── Routes ───────────────────────────────────────────────────────────────────

// Health
app.get('/health', async (_req, res) => {
  try {
    await db.query('SELECT 1');
    res.json({ status: 'UP', db: 'connected', ts: new Date().toISOString() });
  } catch (err) {
    res.status(503).json({ status: 'DOWN', error: err.message });
  }
});

// GET /api/games/:gameCode  — fetch game data from GDS
app.get('/api/games/:gameCode', async (req, res) => {
  const { gameCode } = req.params;
  try {
    const r = await axios.get(`${GDS_URL}/gds/games/${gameCode}`, { timeout: 5000 });
    res.json(r.data);
  } catch (err) {
    const status = err.response?.status || 502;
    const data   = err.response?.data   || { message: err.message };
    console.error(`[gds] GET /gds/games/${gameCode} → ${status}`);
    res.status(status).json({ status: 'GDS_ERROR', ...data });
  }
});

// POST /api/wager/purchase  — full purchase flow
//
// Flow:
//   1. Fetch game data from GDS (validates game is active, gets ticket price)
//   2. Check account balance via ESB
//   3. Submit purchase to ESB
//   4. Persist transaction locally
app.post('/api/wager/purchase', async (req, res) => {
  const { gameCode, wagerAmount, playerId, drawDate, numbers } = req.body;

  if (!gameCode || !wagerAmount || !playerId) {
    return res.status(400).json({
      status: 'ERROR',
      message: 'gameCode, wagerAmount and playerId are required',
    });
  }

  // ── Step 1: GDS — get game data ──────────────────────────────────────────
  let gameData;
  try {
    const r = await axios.get(`${GDS_URL}/gds/games/${gameCode}`, { timeout: 5000 });
    gameData = r.data;
  } catch (err) {
    const status = err.response?.status || 502;
    console.error(`[gds] game data fetch failed for ${gameCode}: ${status}`);
    await logTransaction(null, gameCode, playerId, wagerAmount, 'GDS_ERROR');
    return upstreamError(res, 502, {
      status: 'GDS_ERROR',
      message: 'Failed to fetch game data',
      errorCode: `GDS-${status}`,
    });
  }

  if (gameData.status !== 'ACTIVE') {
    await logTransaction(null, gameCode, playerId, wagerAmount, 'GAME_NOT_ACTIVE');
    return upstreamError(res, 422, {
      status: 'GAME_NOT_ACTIVE',
      message: `Game ${gameCode} is not currently active`,
    });
  }

  // ── Step 2: ESB — check account balance ─────────────────────────────────
  let balance;
  try {
    const r = await axios.get(`${ESB_URL}/esb/account/balance`, {
      params:  { gameCode },
      timeout: 5000,
    });
    balance = r.data.balance;
  } catch (err) {
    const status = err.response?.status;
    const data   = err.response?.data || {};

    // P5 scenario: ESB itself returns 503 (host no issue)
    if (status === 503) {
      await logTransaction(null, gameCode, playerId, wagerAmount, 'HOST_NO_ISSUE');
      return upstreamError(res, 503, {
        status:    'HOST_NO_ISSUE',
        message:   'GDS host unavailable',
        errorCode: 'ESB-503',
        retryable: true,
      });
    }
    console.error(`[esb] balance check failed for ${gameCode}: ${status}`);
    await logTransaction(null, gameCode, playerId, wagerAmount, 'ESB_ERROR');
    return upstreamError(res, 502, { status: 'ESB_ERROR', message: 'Balance check failed' });
  }

  // PB scenario: balance too low
  if (balance < wagerAmount) {
    await logTransaction(null, gameCode, playerId, wagerAmount, 'NO_FUNDS');
    return upstreamError(res, 402, {
      status:      'NO_FUNDS',
      message:     'Insufficient funds',
      errorCode:   'ESB-402',
      wagerAmount,
      balance,
    });
  }

  // ── Step 3: ESB — submit purchase ────────────────────────────────────────
  let purchaseResult;
  try {
    const r = await axios.post(`${ESB_URL}/esb/purchase`, {
      gameCode,
      wagerAmount,
      playerId,
      drawDate:  drawDate || gameData.drawDate,
      numbers:   numbers  || [],
    }, { timeout: 8000 });
    purchaseResult = r.data;
  } catch (err) {
    const status = err.response?.status;
    const data   = err.response?.data || {};
    console.error(`[esb] purchase failed for ${gameCode}: ${status}`);

    if (status === 402) {
      await logTransaction(null, gameCode, playerId, wagerAmount, 'NO_FUNDS');
      return upstreamError(res, 402, { status: 'NO_FUNDS', ...data });
    }
    if (status === 503) {
      await logTransaction(null, gameCode, playerId, wagerAmount, 'HOST_NO_ISSUE');
      return upstreamError(res, 503, { status: 'HOST_NO_ISSUE', ...data });
    }
    await logTransaction(null, gameCode, playerId, wagerAmount, 'ESB_ERROR');
    return upstreamError(res, 502, { status: 'ESB_ERROR', message: 'Purchase submission failed' });
  }

  // ── Step 4: persist and return ───────────────────────────────────────────
  const txnId = await logTransaction(
    purchaseResult.transactionId,
    gameCode, playerId, wagerAmount, 'OK'
  );

  return res.status(200).json({
    ...purchaseResult,
    transactionId: txnId,
    status:        'OK',
    gameName:      gameData.gameName,
  });
});

// GET /api/wager/transaction/:txnId  — look up a persisted transaction
app.get('/api/wager/transaction/:txnId', async (req, res) => {
  try {
    const [rows] = await db.query(
      'SELECT * FROM wager_transactions WHERE transaction_id = ?',
      [req.params.txnId]
    );
    if (!rows.length) {
      return res.status(404).json({ status: 'NOT_FOUND', message: 'Transaction not found' });
    }
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ status: 'ERROR', message: err.message });
  }
});

// ─── Bootstrap ────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`[wager-app] listening on :${PORT}`);
  console.log(`[wager-app] GDS_URL=${GDS_URL}`);
  console.log(`[wager-app] ESB_URL=${ESB_URL}`);
});
