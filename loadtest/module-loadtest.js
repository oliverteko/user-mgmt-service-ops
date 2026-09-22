// Load test for the module_service, driven through the user_mgmt_service
// backend exactly like a real client: every iteration lists the available
// modules (GET /modules) and assigns one to the test user
// (PUT /users/{id}/modules/{moduleId}). Each iteration = 3 requests to the
// module_service (list, availability check, assignment) behind the backend's
// timeout/retry/circuit-breaker client. The module_service isn't reachable
// directly anyway (NetworkPolicy module-service-ingress only admits the
// backend).
//
// Used to size moduleService.resources (vertical scaling) - watch the
// "user-mgmt-service / Module Service" Grafana dashboard while it runs.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.TARGET_HOST || 'http://backend:8080';

const assignErrors = new Rate('assign_errors');

export const options = {
  scenarios: {
    ramping_module_load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '1m', target: 40 },
        { duration: '3m', target: 40 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    assign_errors: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

export function setup() {
  const email = `k6-modules-${Date.now()}@example.com`;
  const password = 'LoadTest123!';
  const json = { headers: { 'Content-Type': 'application/json' } };

  const register = http.post(`${BASE_URL}/users/register`,
    JSON.stringify({ firstName: 'K6', lastName: 'Modules', email, password }), json);
  if (register.status !== 201) {
    throw new Error(`setup: register failed ${register.status}: ${register.body}`);
  }
  const login = http.post(`${BASE_URL}/users/login`, JSON.stringify({ email, password }), json);
  const token = login.headers['Authorization'];
  if (!token) {
    throw new Error(`setup: login failed ${login.status}`);
  }
  const auth = { headers: { Authorization: token } };
  const userId = http.get(`${BASE_URL}/users/me`, auth).json('id');
  const moduleIds = http.get(`${BASE_URL}/modules`, auth).json().map((m) => m.id);
  return { token, userId, moduleIds };
}

export default function (data) {
  const auth = { headers: { Authorization: data.token } };

  const list = http.get(`${BASE_URL}/modules`, auth);
  check(list, { 'list status is 200': (r) => r.status === 200 });

  const moduleId = data.moduleIds[Math.floor(Math.random() * data.moduleIds.length)];
  const assign = http.put(`${BASE_URL}/users/${data.userId}/modules/${moduleId}`, null, auth);
  const ok = check(assign, { 'assign status is 200': (r) => r.status === 200 });
  assignErrors.add(!ok);

  sleep(0.5);
}
