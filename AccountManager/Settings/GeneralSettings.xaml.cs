using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace AccountManager.Settings
{
    /// <summary>
    /// Interaction logic for GeneralSettings.xaml
    /// </summary>
    public partial class GeneralSettings : UserControl
    {
        public Data Data { get => Data.Instance; }

        public GeneralSettings()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
        }

        private void ExportButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SaveFileDialog();
            dialog.Filter = "json file (.json)|*.json";

            if(dialog.ShowDialog() == true)
            {
                Data.Instance.SaveConfig(dialog.FileName);
            }
        }

        private void ImportButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFileDialog();
            dialog.Filter = "json file (.json)|*.json";

            if (dialog.ShowDialog() == true)
            {
                Data.Instance.LoadConfig(dialog.FileName);
                Data.Instance.SaveConfig();
            }
        }
    }
}
