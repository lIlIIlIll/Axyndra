import unittest
from product_unit_gate import has_compiler_error

class CompilerDiagnosticTests(unittest.TestCase):
    def test_rejects_actual_plain_and_colored_compiler_errors(self):
        for text in ['error: bad input', 'Error: cjpm test failed', 'fatal error: broken link',
                     '\x1b[31merror\x1b[0m: unknown identifier', 'warning: earlier\nerror: later']:
            self.assertTrue(has_compiler_error(text))
    def test_warning_source_parameter_is_not_a_compiler_error(self):
        self.assertFalse(has_compiler_error('warning: unused function\n87 | func memoryLiveErrorValue(error:AgentError):AgentValue{\ncjpm build success'))
        self.assertFalse(has_compiler_error('87 | func f(\x1b[31merror:AgentError\x1b[0m)'))
    def test_both_warning_source_and_later_actual_error_remain_rejected(self):
        self.assertTrue(has_compiler_error('87 | func f(error:AgentError)\n  \x1b[31mError\x1b[0m: failed to compile'))

if __name__ == '__main__':
    unittest.main()
