using AccountApi;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;


namespace AccountManager.Views.Log
{
    /// <summary>
    /// Interaction logic for Log.xaml
    /// </summary>
    public partial class Log : UserControl, ILog
    {
        public bool ShowErrors { set; get; } = true;
        public bool ShowMessages { set; get; } = true;

        List<LogEntry> entries = new List<LogEntry>();
        ObservableCollection<LogEntry> VisibleEntries = new ObservableCollection<LogEntry>();

        public Origin Filter { get; set; } = Origin.All;

        public Log()
        {
            InitializeComponent();
            LogList.ItemsSource = VisibleEntries;
        }

        private void ErrorsButton_Click(object sender, RoutedEventArgs e)
        {
            ShowErrors = !ShowErrors;
            Rebuild();

            if (ShowErrors)
            {
                ErrorsButton.Style = this.FindResource("MaterialDesignRaisedButton") as Style;
            }
            else
            {
                ErrorsButton.Style = this.FindResource("MaterialDesignFlatButton") as Style;
            }

        }

        private void WarningsButton_Click(object sender, RoutedEventArgs e)
        {
            ShowMessages = !ShowMessages;
            Rebuild();

            if (ShowMessages)
            {
                WarningsButton.Style = this.FindResource("MaterialDesignRaisedButton") as Style;
            }
            else
            {
                WarningsButton.Style = this.FindResource("MaterialDesignFlatButton") as Style;
            }
        }

        private void Rebuild()
        {
            VisibleEntries.Clear();
            int errors = 0;
            int messages = 0;

            for (int i = entries.Count - 1; i >= 0; i--)
            {
                if (entries[i].Error)
                {
                    errors++;
                }
                else
                {
                    messages++;
                }

                if (entries[i].Error && !ShowErrors) continue;
                if (!entries[i].Error && !ShowMessages) continue;

                if (Filter == Origin.All || Filter == entries[i].Origin)
                {
                    VisibleEntries.Add(entries[i]);
                }
            }
            VisibleEntries.Reverse();
            MessagesBadge.Badge = messages.ToString();
            ErrorsBadge.Badge = errors.ToString();
        }

        public void AddMessage(Origin origin, string message)
        {
            entries.Add(new LogEntry
            {
                Origin = origin,
                Content = message,
                Error = false,
            });
            Application.Current.Dispatcher.Invoke(new System.Action(() => Rebuild()));
        }

        public void AddError(Origin origin, string message)
        {
            entries.Add(new LogEntry
            {
                Origin = origin,
                Content = message,
                Error = true,
            });
            Console.WriteLine("Error: " + message);
            Application.Current.Dispatcher.Invoke(new System.Action(() => Rebuild()));
        }

        private void OriginSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            string selected = (OriginSelector.SelectedValue as ComboBoxItem).Content?.ToString();
            if (selected == null) return;

            switch (selected)
            {
                case "All": Filter = Origin.All; break;
                case "Wisa": Filter = Origin.Wisa; break;
                case "SmartSchool": Filter = Origin.Smartschool; break;
                case "Office365": Filter = Origin.Azure; break;
                case "Other": Filter = Origin.Other; break;
            }

            Rebuild();
        }
    }
}