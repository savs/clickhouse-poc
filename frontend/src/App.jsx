import { useState } from 'react';

const CITIES = ['Paris', 'New York', 'Tokyo', 'London'];
const BLUE = '#00256c';

async function gql(query, variables = {}) {
  const res = await fetch('/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors?.length) throw new Error(json.errors[0].message);
  return json.data;
}

const SEARCH_QUERY = `
  query Search($location: String, $from: String!, $to: String!) {
    hotels(location: $location) { id name location pricePerNight rating available }
    flights(from: $from, to: $to) { id airline flightNumber from to departure arrival durationHours price available }
  }
`;

const BOOK_MUTATION = `
  mutation Book($hotelId: ID, $flightId: ID) {
    bookTrip(hotelId: $hotelId, flightId: $flightId) {
      id totalPrice status
      hotel { name location }
      flight { airline flightNumber from to }
    }
  }
`;

function HotelCard({ hotel, inCart, onAdd, onRemove }) {
  return (
    <div style={{
      background: '#fff',
      border: `2px solid ${inCart ? BLUE : '#e8eef5'}`,
      borderRadius: 10,
      padding: 16,
      marginBottom: 10,
      opacity: hotel.available ? 1 : 0.55,
      boxShadow: inCart ? `0 0 0 3px rgba(0,37,108,0.10)` : '0 1px 4px rgba(0,0,0,0.06)',
      transition: 'border-color 0.15s',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{hotel.name}</div>
          <div style={{ color: '#666', fontSize: 13, marginTop: 2 }}>{hotel.location}</div>
          <div style={{ marginTop: 8, display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ fontWeight: 700, color: BLUE, fontSize: 16 }}>
              ${hotel.pricePerNight}
              <span style={{ fontWeight: 400, fontSize: 12, color: '#888' }}>/night</span>
            </span>
            <span style={{ color: '#f0a500', fontSize: 13 }}>★ {hotel.rating}</span>
            {!hotel.available && (
              <span style={{ fontSize: 11, background: '#f5f5f5', borderRadius: 4, padding: '2px 7px', color: '#888' }}>Sold out</span>
            )}
          </div>
        </div>
        <div>
          {inCart ? (
            <button onClick={onRemove} style={{
              padding: '7px 14px', background: '#fff', color: '#c00',
              border: '1.5px solid #fcc', borderRadius: 6, fontSize: 13,
              fontWeight: 600, cursor: 'pointer', whiteSpace: 'nowrap',
            }}>✕ Remove</button>
          ) : (
            <button onClick={onAdd} disabled={!hotel.available} style={{
              padding: '7px 14px', background: hotel.available ? BLUE : '#eee',
              color: hotel.available ? '#fff' : '#aaa', border: 'none',
              borderRadius: 6, fontSize: 13, fontWeight: 600,
              cursor: hotel.available ? 'pointer' : 'not-allowed', whiteSpace: 'nowrap',
            }}>+ Add to cart</button>
          )}
        </div>
      </div>
    </div>
  );
}

function FlightCard({ flight, inCart, onAdd, onRemove }) {
  return (
    <div style={{
      background: '#fff',
      border: `2px solid ${inCart ? BLUE : '#e8eef5'}`,
      borderRadius: 10,
      padding: 16,
      marginBottom: 10,
      opacity: flight.available ? 1 : 0.55,
      boxShadow: inCart ? `0 0 0 3px rgba(0,37,108,0.10)` : '0 1px 4px rgba(0,0,0,0.06)',
      transition: 'border-color 0.15s',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 700, fontSize: 15 }}>
            {flight.airline}
            <span style={{ fontWeight: 400, fontSize: 13, color: '#888', marginLeft: 6 }}>{flight.flightNumber}</span>
          </div>
          <div style={{ color: '#555', fontSize: 13, marginTop: 4 }}>
            <span style={{ fontWeight: 600 }}>{flight.departure}</span>
            {' → '}
            <span style={{ fontWeight: 600 }}>{flight.arrival}</span>
            <span style={{ color: '#999', marginLeft: 8 }}>{flight.durationHours}h</span>
          </div>
          <div style={{ marginTop: 8, display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ fontWeight: 700, color: BLUE, fontSize: 16 }}>${flight.price}</span>
            {!flight.available && (
              <span style={{ fontSize: 11, background: '#f5f5f5', borderRadius: 4, padding: '2px 7px', color: '#888' }}>Sold out</span>
            )}
          </div>
        </div>
        <div>
          {inCart ? (
            <button onClick={onRemove} style={{
              padding: '7px 14px', background: '#fff', color: '#c00',
              border: '1.5px solid #fcc', borderRadius: 6, fontSize: 13,
              fontWeight: 600, cursor: 'pointer', whiteSpace: 'nowrap',
            }}>✕ Remove</button>
          ) : (
            <button onClick={onAdd} disabled={!flight.available} style={{
              padding: '7px 14px', background: flight.available ? BLUE : '#eee',
              color: flight.available ? '#fff' : '#aaa', border: 'none',
              borderRadius: 6, fontSize: 13, fontWeight: 600,
              cursor: flight.available ? 'pointer' : 'not-allowed', whiteSpace: 'nowrap',
            }}>+ Add to cart</button>
          )}
        </div>
      </div>
    </div>
  );
}

function Cart({ cart, total, onRemoveHotel, onRemoveFlight, onCheckout, loading }) {
  const isEmpty = !cart.hotel && !cart.flight;
  const itemCount = (cart.hotel ? 1 : 0) + (cart.flight ? 1 : 0);

  return (
    <div style={{
      background: '#fff', borderRadius: 12, padding: 20,
      boxShadow: '0 2px 12px rgba(0,0,0,0.10)', border: '1px solid #e8eef5',
      position: 'sticky', top: 24,
    }}>
      <div style={{ fontWeight: 700, fontSize: 16, color: '#222', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }}>
        🛒 Your Trip
        {!isEmpty && (
          <span style={{
            fontSize: 12, background: BLUE, color: '#fff',
            borderRadius: 99, padding: '2px 8px', fontWeight: 600,
          }}>{itemCount}</span>
        )}
      </div>

      {isEmpty ? (
        <div style={{ color: '#aaa', fontSize: 14, textAlign: 'center', padding: '28px 0' }}>
          <div style={{ fontSize: 36, marginBottom: 8 }}>🧳</div>
          Add a hotel or flight<br />to get started
        </div>
      ) : (
        <>
          {cart.hotel && (
            <div style={{ marginBottom: 10, padding: 12, background: '#f8fafc', borderRadius: 8, border: '1px solid #e8eef5' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 11, fontWeight: 700, color: '#888', textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 3 }}>Hotel</div>
                  <div style={{ fontWeight: 600, fontSize: 14 }}>{cart.hotel.name}</div>
                  <div style={{ fontSize: 13, color: '#666', marginTop: 2 }}>{cart.hotel.location}</div>
                  <div style={{ fontWeight: 700, color: BLUE, marginTop: 4, fontSize: 14 }}>
                    ${cart.hotel.pricePerNight}
                    <span style={{ fontWeight: 400, fontSize: 12, color: '#888' }}>/night</span>
                  </div>
                </div>
                <button onClick={onRemoveHotel} style={{
                  background: 'none', border: 'none', color: '#bbb',
                  cursor: 'pointer', fontSize: 18, padding: 4, lineHeight: 1,
                }}>✕</button>
              </div>
            </div>
          )}

          {cart.flight && (
            <div style={{ marginBottom: 10, padding: 12, background: '#f8fafc', borderRadius: 8, border: '1px solid #e8eef5' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 11, fontWeight: 700, color: '#888', textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 3 }}>Flight</div>
                  <div style={{ fontWeight: 600, fontSize: 14 }}>{cart.flight.airline} {cart.flight.flightNumber}</div>
                  <div style={{ fontSize: 13, color: '#666', marginTop: 2 }}>{cart.flight.from} → {cart.flight.to}</div>
                  <div style={{ fontWeight: 700, color: BLUE, marginTop: 4, fontSize: 14 }}>${cart.flight.price}</div>
                </div>
                <button onClick={onRemoveFlight} style={{
                  background: 'none', border: 'none', color: '#bbb',
                  cursor: 'pointer', fontSize: 18, padding: 4, lineHeight: 1,
                }}>✕</button>
              </div>
            </div>
          )}

          <div style={{ borderTop: '1px solid #e8eef5', paddingTop: 14, marginTop: 4 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
              <span style={{ fontWeight: 600, color: '#444', fontSize: 14 }}>Estimated total</span>
              <span style={{ fontWeight: 800, fontSize: 20, color: BLUE }}>${total}</span>
            </div>
            <button onClick={onCheckout} disabled={loading} style={{
              width: '100%', padding: '12px 0',
              background: loading ? '#aaa' : BLUE,
              color: '#fff', border: 'none', borderRadius: 8,
              fontSize: 15, fontWeight: 700,
              cursor: loading ? 'default' : 'pointer',
            }}>
              {loading ? 'Booking…' : 'Checkout →'}
            </button>
          </div>
        </>
      )}
    </div>
  );
}

export default function App() {
  const [from, setFrom] = useState('New York');
  const [to, setTo] = useState('Paris');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [results, setResults] = useState(null);
  const [cart, setCart] = useState({ hotel: null, flight: null });
  const [booking, setBooking] = useState(null);

  const search = async (e) => {
    e.preventDefault();
    setLoading(true); setError(null); setResults(null);
    setCart({ hotel: null, flight: null }); setBooking(null);
    try {
      setResults(await gql(SEARCH_QUERY, { location: to, from, to }));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const checkout = async () => {
    setLoading(true); setError(null);
    try {
      const data = await gql(BOOK_MUTATION, {
        hotelId: cart.hotel?.id ?? null,
        flightId: cart.flight?.id ?? null,
      });
      setBooking(data.bookTrip);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const reset = () => {
    setResults(null); setCart({ hotel: null, flight: null });
    setBooking(null); setError(null);
  };

  const cartTotal = (cart.hotel?.pricePerNight ?? 0) + (cart.flight?.price ?? 0);

  return (
    <div style={{ fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif', minHeight: '100vh', background: '#f0f4f8' }}>

      <header style={{ background: BLUE, color: '#fff', padding: '14px 32px', display: 'flex', alignItems: 'center', gap: 12 }}>
        <span style={{ fontSize: 26 }}>✈️</span>
        <span style={{ fontSize: 20, fontWeight: 700 }}>Travel Booking</span>
        <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 20 }}>
          <a href={window.__GRAFANA_URL__ || 'http://localhost:3000'} target="_blank" rel="noreferrer"
            style={{ color: '#fff', fontSize: 13, fontWeight: 600, textDecoration: 'none', opacity: 0.85, display: 'flex', alignItems: 'center', gap: 6 }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 14H9V8h2v8zm4 0h-2V8h2v8z"/></svg>
            Grafana
          </a>
          <span style={{ fontSize: 11, opacity: 0.45 }}>Observability demo · Grafana + ClickHouse</span>
        </span>
      </header>

      <main style={{ maxWidth: 1160, margin: '0 auto', padding: '32px 24px' }}>

        {/* Search form */}
        <form onSubmit={search} style={{
          background: '#fff', borderRadius: 12, padding: 24,
          boxShadow: '0 2px 8px rgba(0,0,0,0.08)',
          display: 'flex', gap: 16, alignItems: 'flex-end',
          marginBottom: 32, flexWrap: 'wrap',
        }}>
          {[['From', from, setFrom], ['To', to, setTo]].map(([label, value, setter]) => (
            <label key={label} style={{ display: 'flex', flexDirection: 'column', gap: 6, fontSize: 13, fontWeight: 600, color: '#444' }}>
              {label}
              <select value={value} onChange={e => setter(e.target.value)}
                style={{ padding: '9px 14px', border: '1px solid #ddd', borderRadius: 6, fontSize: 15, background: '#fff', minWidth: 160 }}>
                {CITIES.map(c => <option key={c}>{c}</option>)}
              </select>
            </label>
          ))}
          <button type="submit" disabled={loading || from === to} style={{
            padding: '10px 28px',
            background: (loading || from === to) ? '#aaa' : BLUE,
            color: '#fff', border: 'none', borderRadius: 6,
            fontSize: 15, fontWeight: 600,
            cursor: (loading || from === to) ? 'default' : 'pointer',
          }}>
            {loading ? 'Searching…' : 'Search'}
          </button>
        </form>

        {error && (
          <div style={{ background: '#fff5f5', border: '1px solid #fcc', borderRadius: 8, padding: '12px 16px', color: '#c00', marginBottom: 24 }}>
            {error}
          </div>
        )}

        {/* Confirmation */}
        {booking && (
          <div style={{ background: '#fff', borderRadius: 16, padding: 48, textAlign: 'center', boxShadow: '0 4px 24px rgba(0,0,0,0.10)', maxWidth: 520, margin: '0 auto' }}>
            <div style={{ fontSize: 56 }}>🎉</div>
            <h2 style={{ fontSize: 24, fontWeight: 700, margin: '16px 0 8px' }}>Booking Confirmed!</h2>
            <p style={{ color: '#888', marginBottom: 24 }}>
              Reference: <code style={{ background: '#f0f4f8', padding: '2px 8px', borderRadius: 4, fontSize: 13 }}>{booking.id}</code>
            </p>
            {booking.hotel  && <p style={{ marginBottom: 8 }}>🏨 {booking.hotel.name}, {booking.hotel.location}</p>}
            {booking.flight && <p style={{ marginBottom: 8 }}>✈️ {booking.flight.airline} {booking.flight.flightNumber} · {booking.flight.from} → {booking.flight.to}</p>}
            <p style={{ fontSize: 22, fontWeight: 700, color: BLUE, margin: '20px 0 28px' }}>${booking.totalPrice}</p>
            <button onClick={reset} style={{
              padding: '10px 24px', background: BLUE, color: '#fff',
              border: 'none', borderRadius: 6, fontSize: 15, fontWeight: 600, cursor: 'pointer',
            }}>
              Search Again
            </button>
          </div>
        )}

        {/* Results + cart */}
        {results && !booking && (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 300px', gap: 32, alignItems: 'start' }}>

            {/* Left: listings */}
            <div>
              <section style={{ marginBottom: 36 }}>
                <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12, color: '#222' }}>
                  🏨 Hotels in {to}
                  <span style={{ fontWeight: 400, color: '#999', marginLeft: 6 }}>({results.hotels.length})</span>
                </h2>
                {results.hotels.length === 0
                  ? <p style={{ color: '#888' }}>No hotels found.</p>
                  : results.hotels.map(h => (
                    <HotelCard
                      key={h.id}
                      hotel={h}
                      inCart={cart.hotel?.id === h.id}
                      onAdd={() => setCart(c => ({ ...c, hotel: h }))}
                      onRemove={() => setCart(c => ({ ...c, hotel: null }))}
                    />
                  ))}
              </section>

              <section>
                <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12, color: '#222' }}>
                  ✈️ Flights {from} → {to}
                  <span style={{ fontWeight: 400, color: '#999', marginLeft: 6 }}>({results.flights.length})</span>
                </h2>
                {results.flights.length === 0
                  ? <p style={{ color: '#888' }}>No flights found.</p>
                  : results.flights.map(f => (
                    <FlightCard
                      key={f.id}
                      flight={f}
                      inCart={cart.flight?.id === f.id}
                      onAdd={() => setCart(c => ({ ...c, flight: f }))}
                      onRemove={() => setCart(c => ({ ...c, flight: null }))}
                    />
                  ))}
              </section>
            </div>

            {/* Right: cart */}
            <Cart
              cart={cart}
              total={cartTotal}
              onRemoveHotel={() => setCart(c => ({ ...c, hotel: null }))}
              onRemoveFlight={() => setCart(c => ({ ...c, flight: null }))}
              onCheckout={checkout}
              loading={loading}
            />
          </div>
        )}

      </main>
    </div>
  );
}
