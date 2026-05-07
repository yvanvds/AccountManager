using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;
using System.Windows.Media;

namespace AccountManager.Utils
{
    public class FlowTableCreator
    {
        bool showDifferences;

        string[] headers;

        List<List<string>> rowContents = new List<List<string>>();

        public FlowTableCreator(bool showDifferences)
        {
            this.showDifferences = showDifferences;
        }

        public void SetHeaders(string[] headers)
        {
            this.headers = headers;
        }

        public void AddRow(List<string> row)
        {
            rowContents.Add(row);
        }

        public Table Create()
        {
            Table t = new Table();
            t.CellSpacing = 10;
            t.Background = Brushes.White;

            addColumns(t);
            t.RowGroups.Add(new TableRowGroup());
            addHeaders(t);

            for(int i = 0; i < rowContents.Count; i++) {
                addRow(t, i);
            }

            return t;
        }

        private void addColumns(Table t)
        {
            for (int i = 0; i <= headers.Length; i++)
            {
                t.Columns.Add(new TableColumn());
            }
            t.Columns[0].Background = Brushes.Bisque;
        }

        private void addHeaders(Table t)
        {
            t.RowGroups[0].Rows.Add(new TableRow());
            var currentRow = t.RowGroups[0].Rows[0];
            currentRow.Background = Brushes.Silver;
            currentRow.FontSize = 20;
            currentRow.FontWeight = System.Windows.FontWeights.Bold;

            currentRow.Cells.Add(new TableCell());
            for(int i = 0; i < headers.Length; i++)
            {
                currentRow.Cells.Add(new TableCell(new Paragraph(new Run(headers[i]))));
            }
        }

        private void addRow(Table t, int row)
        {
            t.RowGroups[0].Rows.Add(new TableRow());
            var currentRow = t.RowGroups[0].Rows[row + 1];

            for(int i = 0; i < rowContents[row].Count; i++)
            {
                var p = new Paragraph(new Run(rowContents[row][i]));
                if (showDifferences)
                {
                    if (i == 1) p.Foreground = Brushes.DarkGreen;
                    else if (i == 2)
                    {
                        if (rowContents[row][1] == rowContents[row][2])
                        {
                            p.Foreground = Brushes.DarkGreen;
                        } else
                        {
                            p.Foreground = Brushes.DarkRed;
                        }
                    }
                    else
                    {
                        p.Foreground = Brushes.Black;
                    }
                } else
                {
                    p.Foreground = Brushes.Black;
                }
                currentRow.Cells.Add(new TableCell(p));
            }
        }
    }
}
