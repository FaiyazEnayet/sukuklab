"""SukukLab presentation configuration."""
CONFIGS = {'sukuklab': {'name': 'SukukLab',
              'display': 'Fraunces',
              'body': 'IBM Plex Mono',
              'mono': 'IBM Plex Mono',
              'colors': ['#f3efe3', '#fcf9ef', '#15365e', '#516278', '#765b20', '#bcc4cc'],
              'series': ['#224e82', '#957123', '#8c4c3e', '#377267'],
              'control': 'structure',
              'question': 'How do yield, contract structure and dated cash flows shape value and '
                          'risk?',
              'brief': 'IILM observation context · January 2026',
              'classification': 'January 2026 IILM observations and explicitly modeled cash-flow '
                                'examples',
              'north': 'Let a treasury learner connect yield sensitivity to explicit dated payment '
                       'mechanics and rate conventions.',
              'layout': 'Treasury folio with a broad price–yield chart and narrow instrument '
                        'ledger; curve and contract schedules follow.',
              'limits': ['The IILM curve is a January 2026 snapshot, not current market pricing. '
                         'Auction inputs are simple annualized rates; the curve displays '
                         'continuously compounded zero rates.',
                         'Pricing uses nominal annual yield compounded semiannually and '
                         'Actual/365. Values are currency units per face 1,000.',
                         'The example schedules are modeled instruments. Structure labels do not '
                         'establish legal or Sharia compliance.',
                         'The Python alternative ports the existing Julia formulas and verifies '
                         'the default values against the original Julia-generated snapshot.'],
              'sources': ['docs/dashboard.html',
                          'examples/make_dashboard.jl',
                          'src/analytics.jl',
                          'src/cashflows.jl',
                          'src/curve.jl',
                          'data/iilm_2026-01.json']}}
