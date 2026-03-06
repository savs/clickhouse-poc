/**
 * load-test.js — k6 load test for the travel booking demo.
 *
 * Simulates realistic user journeys:
 *   1. Load the homepage (authenticated)
 *   2. Search for flights + hotels (GraphQL query)
 *   3. Select an available flight and hotel
 *   4. Complete the booking (GraphQL mutation)
 *
 * Run locally:
 *   ./run_load_test.sh -url https://frontend.demo.example.com
 *
 * Run via K6 Cloud:
 *   ./run_load_test.sh -url https://frontend.demo.example.com -cloud
 *
 * Environment variables (set by run_load_test.sh from .env):
 *   BASE_URL         — frontend base URL, e.g. https://prefix.frontend.domain.com
 *   FRONTEND_USER    — basic auth username
 *   FRONTEND_PASSWORD — basic auth password
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';
import { b64encode } from 'k6/encoding';
import { randomItem } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// ── Custom metrics ────────────────────────────────────────────────────────────
const searchErrorRate  = new Rate('search_errors');
const bookingErrorRate = new Rate('booking_errors');
const bookingDuration  = new Trend('booking_duration_ms', true);

// ── Load profile ──────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '30s', target: 5  },   // ramp up
    { duration: '2m',  target: 10 },   // sustain moderate load
    { duration: '30s', target: 25 },   // spike
    { duration: '1m',  target: 25 },   // sustain spike
    { duration: '30s', target: 5  },   // ramp down
    { duration: '30s', target: 0  },   // drain
  ],
  thresholds: {
    // 95% of requests under 3 s, 99% under 8 s
    http_req_duration:    ['p(95)<3000', 'p(99)<8000'],
    // GraphQL errors stay below 5%
    search_errors:        ['rate<0.05'],
    booking_errors:       ['rate<0.05'],
    // Booking mutations complete under 5 s at p95
    booking_duration_ms:  ['p(95)<5000'],
  },
};

// ── Test data ─────────────────────────────────────────────────────────────────
const CITIES = ['Paris', 'New York', 'Tokyo', 'London'];

const SEARCH_QUERY = `
  query Search($location: String, $from: String!, $to: String!) {
    hotels(location: $location) {
      id name location pricePerNight rating available
    }
    flights(from: $from, to: $to) {
      id airline flightNumber from to departure arrival durationHours price available
    }
  }
`;

const BOOK_MUTATION = `
  mutation Book($hotelId: ID, $flightId: ID) {
    bookTrip(hotelId: $hotelId, flightId: $flightId) {
      id
      totalPrice
      status
      hotel  { name location }
      flight { airline flightNumber from to }
    }
  }
`;

// ── Helpers ───────────────────────────────────────────────────────────────────
const BASE_URL         = __ENV.BASE_URL         || 'http://localhost:8080';
const FRONTEND_USER    = __ENV.FRONTEND_USER    || 'traveldemo';
const FRONTEND_PASSWORD = __ENV.FRONTEND_PASSWORD || '';

// Basic auth header value
const AUTH_HEADER = `Basic ${b64encode(`${FRONTEND_USER}:${FRONTEND_PASSWORD}`)}`;

const GRAPHQL_URL = `${BASE_URL}/graphql`;

const commonHeaders = {
  'Content-Type': 'application/json',
  'Authorization': AUTH_HEADER,
};

function gqlPost(body, tags = {}) {
  return http.post(
    GRAPHQL_URL,
    JSON.stringify(body),
    { headers: commonHeaders, tags },
  );
}

function pickAvailable(items) {
  if (!items || items.length === 0) return null;
  const available = items.filter(i => i.available);
  return available.length > 0 ? randomItem(available) : randomItem(items);
}

// ── Main scenario ─────────────────────────────────────────────────────────────
export default function () {
  // Pick a random origin/destination pair (different cities)
  const from     = randomItem(CITIES);
  const others   = CITIES.filter(c => c !== from);
  const to       = randomItem(others);
  const location = to;   // search hotels at destination

  // ── Step 1: Load homepage ────────────────────────────────────────────────
  group('homepage', () => {
    const res = http.get(BASE_URL, { headers: { Authorization: AUTH_HEADER } });
    check(res, {
      'homepage 200': r => r.status === 200,
    });
  });

  sleep(randomBetween(0.5, 1.5));

  // ── Step 2: Search flights + hotels ─────────────────────────────────────
  let hotel  = null;
  let flight = null;

  group('search', () => {
    const res = gqlPost(
      { query: SEARCH_QUERY, variables: { location, from, to } },
      { name: 'graphql_search' },
    );

    const ok = check(res, {
      'search 200':       r => r.status === 200,
      'search no errors': r => {
        try {
          const body = JSON.parse(r.body);
          return !body.errors || body.errors.length === 0;
        } catch { return false; }
      },
      'search has results': r => {
        try {
          const body = JSON.parse(r.body);
          return (body.data?.hotels?.length > 0 || body.data?.flights?.length > 0);
        } catch { return false; }
      },
    });

    searchErrorRate.add(!ok);

    if (ok && res.status === 200) {
      try {
        const body = JSON.parse(res.body);
        hotel  = pickAvailable(body.data?.hotels);
        flight = pickAvailable(body.data?.flights);
      } catch (_) { /* handled by error rate */ }
    }
  });

  sleep(randomBetween(1.0, 3.0));   // user browses results

  // ── Step 3: View individual hotel detail (40% of users) ─────────────────
  if (hotel && Math.random() < 0.4) {
    group('hotel_detail', () => {
      const res = gqlPost(
        {
          query: `query Hotel($id: ID!) { hotel(id: $id) {
            id name location pricePerNight rating available
          }}`,
          variables: { id: hotel.id },
        },
        { name: 'graphql_hotel_detail' },
      );
      check(res, {
        'hotel detail 200': r => r.status === 200,
      });
    });
    sleep(randomBetween(0.5, 1.5));
  }

  // ── Step 4: View individual flight detail (40% of users) ────────────────
  if (flight && Math.random() < 0.4) {
    group('flight_detail', () => {
      const res = gqlPost(
        {
          query: `query Flight($id: ID!) { flight(id: $id) {
            id airline flightNumber from to departure arrival durationHours price available
          }}`,
          variables: { id: flight.id },
        },
        { name: 'graphql_flight_detail' },
      );
      check(res, {
        'flight detail 200': r => r.status === 200,
      });
    });
    sleep(randomBetween(0.5, 1.5));
  }

  // ── Step 5: Book (70% of users who found results) ────────────────────────
  if ((hotel || flight) && Math.random() < 0.7) {
    group('checkout', () => {
      const start = Date.now();

      // Randomly book hotel-only, flight-only, or both
      const roll = Math.random();
      const hotelId  = (roll < 0.8 && hotel)  ? hotel.id  : null;   // 80% include hotel
      const flightId = (roll < 0.9 && flight) ? flight.id : null;   // 90% include flight

      const res = gqlPost(
        { query: BOOK_MUTATION, variables: { hotelId, flightId } },
        { name: 'graphql_book' },
      );

      const elapsed = Date.now() - start;
      bookingDuration.add(elapsed);

      const ok = check(res, {
        'booking 200':       r => r.status === 200,
        'booking confirmed': r => {
          try {
            const body = JSON.parse(r.body);
            return body.data?.bookTrip?.status === 'confirmed';
          } catch { return false; }
        },
        'booking no errors': r => {
          try {
            const body = JSON.parse(r.body);
            return !body.errors || body.errors.length === 0;
          } catch { return false; }
        },
      });

      bookingErrorRate.add(!ok);
    });

    sleep(randomBetween(0.5, 1.0));   // confirmation screen pause
  }

  // Think time before next iteration
  sleep(randomBetween(2.0, 5.0));
}

// ── Utility ───────────────────────────────────────────────────────────────────
function randomBetween(min, max) {
  return min + Math.random() * (max - min);
}
