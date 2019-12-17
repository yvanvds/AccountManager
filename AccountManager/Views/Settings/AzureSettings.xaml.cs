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

namespace AccountManager.Views.Settings
{
    /// <summary>
    /// Interaction logic for AzureSettings.xaml
    /// </summary>
    public partial class AzureSettings : UserControl
    {
        public AzureSettings()
        {
            InitializeComponent();
            DataContext = new ViewModels.Settings.AzureSettings();
        }
    }
}
