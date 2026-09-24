"""Policy tests use generated pixels, never the user's private screenshots."""
import copy
import unittest

from PIL import Image, ImageDraw

from browser_empty_probe import Template, classify


class BrowserEmptyProbeTests(unittest.TestCase):
    def setUp(self):
        self.background = (228, 229, 231)
        self.image = Image.new('RGBA', (200, 160), self.background + (255,))
        draw = ImageDraw.Draw(self.image)
        draw.rectangle((0, 0, 199, 19), fill=(245, 245, 245, 255))
        draw.line((0, 19, 199, 19), fill=(205, 206, 208, 255))
        draw.rounded_rectangle((150, 120, 179, 133), radius=5, fill=(145, 145, 145, 255))
        draw.rectangle((163, 124, 165, 129), fill=(255, 255, 255, 255))
        for y in range(4):
            for x in range(4 - y):
                self.image.putpixel((x, 159 - y), (0, 0, 0, 0))
                self.image.putpixel((199 - x, 159 - y), (0, 0, 0, 0))
        self.template = Template(self.image.copy(), 20, (150, 120, 30, 14), 4, self.background)
        self.analysis = {'status': 'candidate_with_regions', 'backgroundRGB': list(self.background),
                         'backgroundFraction': .997, 'regionsTruncated': False,
                         'regions': [{'bounds': b} for b in [[150, 120, 30, 14], [0, 156, 4, 4], [196, 156, 4, 4]]]}
        self.bounds = [0, 20, 200, 140]
        self.bundles = ['com.apple.Safari']
        self.titles = ['起始页']

    def result(self):
        return classify(self.image, self.analysis, self.bounds, self.bundles, self.titles, self.template)

    def test_only_known_controls_and_corners_are_empty(self):
        result = self.result()
        self.assertEqual(result['decision'], 'empty_browser')
        self.assertEqual(len(result['explained']), 3)

    def test_uniform_white_body_with_window_corners_is_empty(self):
        alpha = self.image.getchannel('A')
        self.image = Image.new('RGBA', self.image.size, (255, 255, 255, 255))
        self.image.putalpha(alpha)
        ImageDraw.Draw(self.image).line((0, 19, 199, 19), fill=(229, 229, 229, 255))
        self.analysis['backgroundRGB'] = [255, 255, 255]
        self.analysis['regions'] = self.analysis['regions'][1:]
        self.titles = ['Website']
        self.assertEqual(self.result()['decision'], 'empty_browser')

    def test_business_label_at_same_location_is_not_a_known_control(self):
        self.image.putpixel((164, 126), (0, 0, 0, 255))
        self.assertEqual(self.result()['reason'], 'unexplained_region')

    def test_content_in_corner_bounding_box_is_not_ignored(self):
        self.image.putpixel((3, 156), (0, 0, 0, 255))
        self.assertEqual(self.result()['reason'], 'unexplained_region')

    def test_extra_region_near_control_is_not_ignored(self):
        self.image.putpixel((181, 130), (0, 0, 0, 255))
        self.analysis['regions'].append({'bounds': [181, 130, 1, 1]})
        self.assertEqual(self.result()['reason'], 'unexplained_region')

    def test_same_pixels_in_another_app_are_out_of_scope(self):
        self.bundles = ['com.example.editor']
        self.assertEqual(self.result()['reason'], 'unsupported_app')

    def test_control_requires_start_page_context(self):
        self.titles = ['Account balance']
        self.assertEqual(self.result()['reason'], 'unexplained_region')

    def test_incomplete_regions_are_not_a_blank_decision(self):
        self.analysis['regionsTruncated'] = True
        self.assertEqual(self.result()['reason'], 'incomplete_analysis')

    def test_uncertain_body_geometry_is_not_accepted(self):
        self.bounds[1] += 1
        self.bounds[3] -= 1
        self.assertEqual(self.result()['reason'], 'unsupported_geometry')

    def test_unfamiliar_background_and_color_profiles_are_kept(self):
        self.analysis['backgroundRGB'] = [20, 120, 30]
        self.assertEqual(self.result()['reason'], 'unsupported_background')
        self.analysis['backgroundRGB'] = list(self.background)
        self.image.info['icc_profile'] = b'unknown'
        self.assertEqual(self.result()['reason'], 'unsupported_color_profile')

    def test_anchor_uses_right_edge_when_window_width_changes(self):
        self.image = Image.new('RGBA', (210, 160), self.background + (255,))
        self.image.paste(self.template.image.crop((0, 0, 150, 160)), (0, 0))
        self.image.paste(self.template.image.crop((150, 0, 200, 160)), (160, 0))
        ImageDraw.Draw(self.image).line((0, 19, 209, 19), fill=(205, 206, 208, 255))
        self.bounds[2] = 210
        self.analysis = copy.deepcopy(self.analysis)
        self.analysis['regions'][0]['bounds'][0] += 10
        self.analysis['regions'][2]['bounds'][0] += 10
        self.assertEqual(self.result()['decision'], 'empty_browser')

    def test_overlapping_bounds_do_not_confuse_control_with_window_corner(self):
        alpha = Image.new('L', self.image.size)
        ImageDraw.Draw(alpha).rounded_rectangle((0, 0, 199, 159), radius=48, fill=255)
        ImageDraw.Draw(alpha).rectangle((0, 0, 199, 111), fill=255)
        self.image.putalpha(alpha)
        self.template.image = self.image.copy()
        self.template.corner_size = 48
        self.analysis['regions'][1]['bounds'] = [0, 112, 48, 48]
        self.analysis['regions'][2]['bounds'] = [152, 112, 48, 48]
        self.assertEqual(self.result()['decision'], 'empty_browser')
        self.image.putpixel((180, 135), (0, 0, 0, 255))
        self.assertEqual(self.result()['reason'], 'unexplained_region')

    def test_translucent_corner_rounding_does_not_become_content(self):
        self.image.putpixel((0, 159), (225, 226, 228, 128))
        self.template.image = self.image.copy()
        self.assertEqual(self.result()['decision'], 'empty_browser')

    def test_changed_toolbar_is_not_hidden_by_guessed_body_bounds(self):
        ImageDraw.Draw(self.image).line((0, 19, 199, 19), fill=self.background + (255,))
        self.assertEqual(self.result()['reason'], 'unverified_body_boundary')


if __name__ == '__main__':
    unittest.main()
