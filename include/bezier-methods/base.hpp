#pragma once

#include <cmath>
#include <complex>
#include <concepts>
#include <numbers>

#include "linalg/numbers.hpp"
#include "linalg/dense.hpp"
#include "linalg/combinatorics.hpp"


namespace bezier {

	using namespace linalg::num;

	template<int N> class MultiIndex {
		const Int8 value[N];

	public:

		constexpr MultiIndex(Int8 a, Int8 b) : value{a,b} {
		}

		constexpr MultiIndex(Int8 a, Int8 b, Int8 c) : value{a,b,c} {}

		inline const Int8 operator[](int index) const { return value[index]; 
		}

		constexpr Int32 sum() const { 
			Int32 s = 0;
            for (auto v : value)
				s += v;
            return s;
		}
	};

	template <Integer... Ts>
    constexpr auto multiindex(Ts &&...ts)
        -> Vector<std::common_type_t<Ts...>, sizeof...(ts)> {
        return {std::forward<Ts>(ts)...};
    }


	/// <summary>
	/// Compute the dimension of the Bezier spline space on a simplex of degree `p` 
	/// and numer of vertices `d`.
	/// </summary>
	template <Integer S, Integer T> S dimsplinespace(T p, T d) {
          return linalg::comb::binomial<S>(p + d - 1, d - 1);
    }






} // namespace splines