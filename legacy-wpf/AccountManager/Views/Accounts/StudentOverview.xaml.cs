using AccountManager.Action;
using MaterialDesignThemes.Wpf;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for Overview.xaml
    /// </summary>
    public partial class StudentOverview : UserControl
    {
        
        public Prop<bool> Working { get; set; } = new Prop<bool>() { Value = false };


        public StudentOverview()
        {
            InitializeComponent();
            
            DataContext = new ViewModels.Accounts.StudentOverview();
        }
    }
}
