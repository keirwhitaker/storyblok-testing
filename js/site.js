$(document).ready(function () {

	/* ----------------------------------------------------------------------------------------------------------
    Scroll to Top
    ---------------------------------------------------------------------------------------------------------- */

	$(window).scroll(function () {
		if ($(this).scrollTop() > 500) {
			$("#scroll-top").fadeIn();
		} else {
			$("#scroll-top").fadeOut();
		}
	});

	$("#scroll-top").click(function () {
		$("body,html").animate({ scrollTop: 0 }, 400);
		return false;
	});

	
});
