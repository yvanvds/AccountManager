using AbstractAccountApi;
using AccountApi;
using MaterialDesignThemes.Wpf;
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
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Settings
{
    /// <summary>
    /// Interaction logic for SmartschoolSettings.xaml
    /// </summary>
    public partial class SmartschoolSettings : UserControl
    {
        public SmartschoolSettings()
        {
            InitializeComponent();
            DataContext = new ViewModels.Settings.SmartschoolSettings();
        }
    }
}
