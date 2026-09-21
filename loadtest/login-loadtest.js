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
// Without it, this is the ~8 minute profile meant to show a full HPA
// scale-up (during the plateau) and scale-down (during the trailing 0-VU
// hold, which relies on staging's 60s scale-down stabilization window -
// backend.autoscaling.scaleDownStabilizationSeconds in values-staging.yaml).
//
// Peak VUs deliberately proportional to what staging can actually run:
// backend.autoscaling maxes out at 3 replicas * 250m CPU limit = 750m total
// (values-staging.yaml) - a first version of this test targeted 50 VUs
// ramping over 2m and, tried live, drove sustained ~250% CPU (i.e. pinned at
// the limit) well before the 2nd/3rd replica could come up and share the
// load, so the Service had zero ready endpoints for minutes at a time
// (99.95% request failure, confirmed via a live k6 run). 15 VUs over a
// gentler 3m ramp still reliably crosses the 70% HPA threshold (bcrypt makes
// even a handful of concurrent logins CPU-heavy) while giving new replicas
// realistic time to come up and take a share before the existing ones are
// overwhelmed.
const stages = __ENV.QUICK_TEST
  ? [
      { duration: '15s', target: 10 },
      { duration: '30s', target: 15 },
      { duration: '30s', target: 0 },
    ]
  : [
      { duration: '30s', target: 5 },
      { duration: '1m', target: 15 },
      { duration: '3m', target: 15 },
      { duration: '30s', target: 0 },
      { duration: '3m', target: 0 },
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
