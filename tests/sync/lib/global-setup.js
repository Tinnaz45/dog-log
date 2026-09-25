// Starts the disposable database and the static app server for the whole run; returns their teardown.
const pg = require('./pgcluster');
const app = require('./static-server');

module.exports = async () => {
  const db = pg.start(Number(process.env.DOGLOG_PGPORT_BASE || 55461));
  const server = await app.start(Number(process.env.DOGLOG_APP_PORT || 55462));
  process.env.DOGLOG_PGHOST = db.host;
  process.env.DOGLOG_PGPORT = String(db.port);
  process.env.DOGLOG_APP_URL = server.url;
  return async () => { await server.close(); db.stop(); };
};
