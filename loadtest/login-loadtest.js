// Ramping-load test against POST /users/login - the login endpoint runs a
// BCrypt password check per request, which is deliberately CPU-expensive,
// making it a realistic driver for the backend HPA (see values-staging.yaml
// backend.autoscaling). setup() registers one throwaway user once per test
// run; every VU iteration then just logs that same user in repeatedly.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.TARGET_HOST || 'http://backend:8080';

const loginErrors = new Rate('login_errors');

// QUICK_TEST=true trims this to ~1.5 minutes for fast iteration/dry runs.
// Without it, this is the ~16 minute profile meant to show a full HPA
// scale-up (during the 50-VU plateau) and scale-down (during the trailing
// 0-VU hold, long enough to clear the default 5 min scale-down stabilization
// window).
const stages = __ENV.QUICK_TEST
  ? [
      { duration: '15s', target: 10 },
      { duration: '30s', target: 30 },
      { duration: '30s', target: 0 },
    ]
  : [
      { duration: '1m', target: 10 },
      { duration: '2m', target: 50 },
      { duration: '5m', target: 50 },
      { duration: '2m', target: 0 },
      { duration: '6m', target: 0 },
    ];

export const options = {
  scenarios: {
    ramping_login_load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages,
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    // Availability during scaling: this should stay low throughout the
    // whole run, including while the HPA is adding/removing pods.
    http_req_failed: ['rate<0.05'],
    login_errors: ['rate<0.05'],
    http_req_duration: ['p(95)<2000'],
  },
};

export function setup() {
  const email = `k6-loadtest-${Date.now()}@example.com`;
  const password = 'LoadTest123!';

  const registerRes = http.post(
    `${BASE_URL}/users/register`,
    JSON.stringify({
      firstName: 'K6',
      lastName: 'LoadTest',
      email,
      password,
    }),
    { headers: { 'Content-Type': 'application/json' } },
  );

  if (registerRes.status !== 201) {
    throw new Error(
      `setup: could not register load-test user, got ${registerRes.status}: ${registerRes.body}`,
    );
  }

  return { email, password };
}

export default function (data) {
  const res = http.post(
    `${BASE_URL}/users/login`,
    JSON.stringify({ email: data.email, password: data.password }),
    { headers: { 'Content-Type': 'application/json' } },
  );

  const ok = check(res, {
    'login status is 200': (r) => r.status === 200,
    'login returns Authorization header': (r) => r.headers['Authorization'] !== undefined,
  });
  loginErrors.add(!ok);

  sleep(1);
}
