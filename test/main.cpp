#include <iostream>
#include <vector>

#include "linalg/dense.hpp"
#include "linalg/numbers.hpp"
#include "linalg/fixed_capacity_array.hpp"

#include "bezier-methods/primatives.hpp"
#include "bezier-methods/base.hpp"

using namespace bezier;

using namespace linalg;
using namespace linalg::num;
using namespace linalg::vector;
using namespace linalg::affine;

int main() {

  constexpr auto a = MultiIndex<2>(1, 2);

  std::cout << "Hello world! a = " << a.sum() << std::endl;
  
  return 0;
}