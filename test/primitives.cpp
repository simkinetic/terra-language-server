#include "test.h"

#include <cmath>
#include <numbers>

#include "linalg/dense.hpp"
#include "linalg/numbers.hpp"

#include "bezier-methods/primatives.hpp"

using namespace bezier;
using namespace linalg::num;

namespace test_primitives {


TEST(primatives, types) {

  EXPECT_TRUE(1 == 1);
}

} // namespace test_primitives