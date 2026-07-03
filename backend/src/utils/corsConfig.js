const normalizeOrigin = (value) => String(value || '').trim().toLowerCase();

const isAllowedSubdomain = (origin, baseDomain) => {
  if (!origin || !baseDomain) {
    return false;
  }

  try {
    const { hostname } = new URL(origin);
    const normalizedBase = normalizeOrigin(baseDomain);

    return hostname === normalizedBase || hostname.endsWith(`.${normalizedBase}`);
  } catch (error) {
    return false;
  }
};

const getAllowedOrigins = () =>
  (process.env.ALLOWED_ORIGINS || '')
    .split(',')
    .map(normalizeOrigin)
    .filter(Boolean);

module.exports = {
  credentials: true,
  origin: (origin, callback) => {
    if (!origin) {
      return callback(null, true);
    }

    const normalizedOrigin = normalizeOrigin(origin);
    const allowedOrigins = getAllowedOrigins();
    const allowedBase = normalizeOrigin(process.env.ALLOWED_BASE_DOMAIN);

    const isLocalDevelopmentOrigin =
      process.env.NODE_ENV === 'development' ||
      normalizedOrigin === 'http://localhost:3000' ||
      normalizedOrigin === 'http://127.0.0.1:3000';

    const isExplicitlyAllowed =
      allowedOrigins.includes(normalizedOrigin) ||
      allowedOrigins.includes('*') ||
      isAllowedSubdomain(normalizedOrigin, allowedBase);

    if (isLocalDevelopmentOrigin || isExplicitlyAllowed) {
      return callback(null, true);
    }

    return callback(new Error('Not allowed by CORS'));
  },
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With'],
  optionsSuccessStatus: 200,
};
