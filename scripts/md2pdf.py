
import sys
import os
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, ListFlowable, ListItem
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_JUSTIFY, TA_LEFT
import markdown
import re

def parse_markdown_to_pdf(input_file, output_file):
    with open(input_file, 'r', encoding='utf-8') as f:
        md_text = f.read()

    doc = SimpleDocTemplate(output_file, pagesize=letter)
    styles = getSampleStyleSheet()
    story = []

    # Custom styles
    styles.add(ParagraphStyle(name='CodeBlock', fontName='Courier', fontSize=8, leading=10, backColor='#f0f0f0'))
    
    # Simple line-based parser (ReportLab doesn't natively support MD)
    # We will convert MD to ReportLab Flowables roughly
    
    lines = md_text.split('\n')
    
    for line in lines:
        line = line.strip()
        if not line:
            story.append(Spacer(1, 6))
            continue
            
        # Headers
        if line.startswith('# '):
            story.append(Paragraph(line[2:], styles['Title']))
            story.append(Spacer(1, 12))
        elif line.startswith('## '):
            story.append(Paragraph(line[3:], styles['Heading2']))
            story.append(Spacer(1, 6))
        elif line.startswith('### '):
            story.append(Paragraph(line[4:], styles['Heading3']))
            story.append(Spacer(1, 6))
        
        # Lists
        elif line.startswith('- ') or line.startswith('* '):
            text = line[2:]
            # Bold processing
            text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
            story.append(Paragraph(f"• {text}", styles['Normal']))
        
        # Blockquotes
        elif line.startswith('> '):
            text = line[2:]
            text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
            story.append(Paragraph(f"<i>{text}</i>", styles['Normal']))
            
        # Code blocks (simplified)
        elif line.startswith('```'):
            continue # Skip fence
            
        else:
            # Normal text
            text = line
            text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
            text = re.sub(r'`(.*?)`', r'<font face="Courier">\1</font>', text)
            story.append(Paragraph(text, styles['Normal']))

    doc.build(story)
    print(f"Generated {output_file}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python md2pdf.py input.md output.pdf")
        sys.exit(1)
        
    parse_markdown_to_pdf(sys.argv[1], sys.argv[2])
